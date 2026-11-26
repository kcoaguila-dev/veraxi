"""Tests for structured PR/diff review (ADR-0007 Phase 2 / WP5)."""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import MagicMock

from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.ingestion.lint_findings import parse_lint_sarif
from backend.routes.code_intel import register_code_intel_routes
from backend.services.pr_review import (
    ReviewRequest,
    run_structured_review,
)


def _sample_ruff_sarif() -> dict:
    return {
        "version": "2.1.0",
        "runs": [
            {
                "tool": {"driver": {"name": "ruff", "rules": [{"id": "F401"}]}},
                "results": [
                    {
                        "ruleId": "F401",
                        "level": "error",
                        "message": {"text": "`os` imported but unused"},
                        "locations": [
                            {
                                "physicalLocation": {
                                    "artifactLocation": {"uri": "pkg/mod.py"},
                                    "region": {"startLine": 1, "endLine": 1},
                                }
                            }
                        ],
                    }
                ],
            }
        ],
    }


def _fake_neo4j() -> MagicMock:
    client = MagicMock()
    client.execute_read.return_value = [
        {
            "path": "pkg/mod.py",
            "repo_key": "acme/repo",
            "symbol": "pkg.mod.handler",
            "callees": ["pkg.db.query"],
        }
    ]
    client.execute_write.return_value = []
    return client


class TestStructuredReview:
    def test_dedupes_overlapping_ai_comment_against_uploaded_sarif(self):
        ai_comments = [
            {
                "path": "pkg/mod.py",
                "line": 1,
                "end_line": 1,
                "severity": "LOW",
                "category": "unused-import",
                "message": "Remove unused `os` import",
            },
            {
                "path": "pkg/mod.py",
                "line": 12,
                "end_line": 15,
                "severity": "HIGH",
                "category": "security",
                "message": "Unsanitized SQL parameter",
            },
        ]
        req = ReviewRequest(
            diff="+++ b/pkg/mod.py\n+import os\n",
            files=["pkg/mod.py"],
            repo="acme/repo",
            lint_sarif=_sample_ruff_sarif(),
        )
        res = run_structured_review(
            req,
            touched_files=["pkg/mod.py"],
            tenant_id="t1",
            neo4j_client=_fake_neo4j(),
            ai_reviewer=lambda _d, _f, _s: ai_comments,
        )
        assert res.summary.lint_finding_count == 1
        assert res.summary.ai_comment_count == 2
        assert res.summary.kept_comment_count == 1
        assert res.summary.dropped_duplicate_count == 1
        assert res.summary.dedupe_drop_rate == 0.5
        assert res.comments[0].category == "security"
        assert res.dropped_duplicates[0].category == "unused-import"

    def test_persists_lint_findings_when_requested(self):
        neo4j = _fake_neo4j()
        req = ReviewRequest(
            diff="",
            files=["pkg/mod.py"],
            lint_sarif=_sample_ruff_sarif(),
            persist_lint_findings=True,
            include_ai_review=False,
        )
        res = run_structured_review(
            req,
            touched_files=["pkg/mod.py"],
            tenant_id="t1",
            neo4j_client=neo4j,
        )
        assert res.summary.lint_finding_count == 1
        assert neo4j.execute_write.called

    def test_server_lint_stays_off_when_flag_disabled(self, monkeypatch, tmp_path):
        called = False

        def _fail_if_called(*_a, **_kw):
            nonlocal called
            called = True
            return []

        monkeypatch.setattr(
            "backend.services.pr_review.collect_lint_findings", _fail_if_called
        )
        monkeypatch.setattr(
            "backend.config.get_config",
            lambda: SimpleNamespace(lint_findings_enabled=False, lint_timeout_sec=30),
        )
        req = ReviewRequest(
            diff="",
            files=["pkg/mod.py"],
            run_server_lint=True,
            root=str(tmp_path),
            include_ai_review=False,
        )
        res = run_structured_review(
            req,
            touched_files=["pkg/mod.py"],
            validated_root=str(tmp_path),
            neo4j_client=_fake_neo4j(),
        )
        assert called is False
        assert res.summary.lint_finding_count == 0

    def test_parse_lint_sarif_relativizes_and_sets_category(self, tmp_path):
        sarif = json.loads(json.dumps(_sample_ruff_sarif()))
        loc = sarif["runs"][0]["results"][0]["locations"][0]["physicalLocation"]
        loc["artifactLocation"]["uri"] = f"file://{tmp_path}/pkg/mod.py"
        findings = parse_lint_sarif(sarif, root=tmp_path)
        assert len(findings) == 1
        assert findings[0]["path"] == "pkg/mod.py"
        assert findings[0]["category"] == "unused-import"


class TestCodeReviewRoute:
    def _client(self, monkeypatch) -> TestClient:
        app = FastAPI()
        monkeypatch.setattr(
            "backend.routes.code_intel._default_neo4j_client", _fake_neo4j
        )
        register_code_intel_routes(
            app,
            lambda: "tenant-test",
            lambda: None,
            None,
        )
        return TestClient(app)

    def test_run_server_lint_requires_root(self, monkeypatch):
        client = self._client(monkeypatch)
        resp = client.post(
            "/api/v1/code/review",
            json={"files": ["pkg/mod.py"], "run_server_lint": True},
        )
        assert resp.status_code == 400

    def test_rejects_traversal_root(self, monkeypatch):
        client = self._client(monkeypatch)
        resp = client.post(
            "/api/v1/code/review",
            json={
                "files": ["pkg/mod.py"],
                "run_server_lint": True,
                "root": "/etc/../etc/passwd",
            },
        )
        assert resp.status_code in (400, 403)

    def test_review_endpoint_returns_structured_response(self, monkeypatch):
        monkeypatch.setattr(
            "backend.services.pr_review._default_ai_reviewer",
            lambda _d, _f, _s: [
                {
                    "path": "pkg/mod.py",
                    "line": 1,
                    "severity": "LOW",
                    "category": "unused-import",
                    "message": "Unused import os",
                }
            ],
        )
        client = self._client(monkeypatch)
        resp = client.post(
            "/api/v1/code/review",
            json={
                "diff": "+++ b/pkg/mod.py\n+import os\n",
                "files": ["pkg/mod.py"],
                "lint_sarif": _sample_ruff_sarif(),
            },
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["tenant_id"] == "tenant-test"
        assert body["summary"]["dropped_duplicate_count"] == 1
        assert body["summary"]["kept_comment_count"] == 0
