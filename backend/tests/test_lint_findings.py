"""Tests for ingestion/lint_findings.py (ADR-0007 Phase 2, WP3).

Tool subprocesses are faked through the injectable ``runner`` seam,
so no real ruff/mypy process runs here; one integration test at the
end exercises the real tools when they are installed.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from types import SimpleNamespace

import pytest

from backend.ingestion import lint_findings
from backend.ingestion.lint_findings import (
    build_sarif_payload,
    collect_lint_findings,
    dedupe_review_comments,
    ingest_lint_findings,
    mypy_records_to_sarif,
    rule_category,
)
from backend.ingestion.sarif import parse_sarif_payload

RUFF_SARIF = {
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
                                "artifactLocation": {"uri": "file:///repo/pkg/mod.py"},
                                "region": {"startLine": 1, "endLine": 1},
                            }
                        }
                    ],
                }
            ],
        }
    ],
}

MYPY_LINE = json.dumps(
    {
        "file": "/repo/pkg/mod.py",
        "line": 4,
        "column": 11,
        "end_line": 4,
        "end_column": 14,
        "message": 'Incompatible return value type (got "str", expected "int")',
        "hint": None,
        "code": "return-value",
        "severity": "error",
    }
)


def _completed(argv, stdout="", returncode=0, stderr=""):
    return subprocess.CompletedProcess(argv, returncode, stdout=stdout, stderr=stderr)


def _runner(ruff_stdout="", mypy_stdout="", ruff_rc=1, mypy_rc=1):
    def run(argv, **_kwargs):
        if argv[0] == "ruff":
            return _completed(argv, stdout=ruff_stdout, returncode=ruff_rc)
        return _completed(argv, stdout=mypy_stdout, returncode=mypy_rc)

    return run


@pytest.fixture()
def sentry_calls(monkeypatch):
    calls: list[BaseException] = []
    monkeypatch.setattr(
        lint_findings.sentry_sdk, "capture_exception", lambda exc: calls.append(exc)
    )
    return calls


class TestCollectFindings:
    def test_ruff_sarif_shape_normalized(self, tmp_path):
        runner = _runner(ruff_stdout=json.dumps(RUFF_SARIF), mypy_stdout="")
        findings = collect_lint_findings(
            ["pkg/mod.py"], root=tmp_path, runner=runner
        )
        # The fake ruff reports file:///repo/... — root here is
        # tmp_path, so the URI cannot be relativized to it and stays
        # absolute; the shape fields are what this test pins.
        assert len(findings) == 1
        finding = findings[0]
        assert finding["tool"] == "ruff"
        assert finding["rule_id"] == "F401"
        assert finding["category"] == "unused-import"
        assert finding["severity"] == "HIGH"
        assert finding["line"] == 1
        assert finding["end_line"] == 1
        assert finding["message"] == "`os` imported but unused"

    def test_ruff_uri_relativized_to_root(self, tmp_path):
        payload = json.loads(json.dumps(RUFF_SARIF))
        uri = payload["runs"][0]["results"][0]["locations"][0]["physicalLocation"]
        uri["artifactLocation"]["uri"] = f"file://{tmp_path}/pkg/mod.py"
        runner = _runner(ruff_stdout=json.dumps(payload), mypy_stdout="")
        findings = collect_lint_findings(["pkg/mod.py"], root=tmp_path, runner=runner)
        assert findings[0]["path"] == "pkg/mod.py"

    def test_mypy_records_become_sarif_findings(self, tmp_path):
        runner = _runner(ruff_stdout=json.dumps({"runs": []}), mypy_stdout=MYPY_LINE)
        findings = collect_lint_findings(["pkg/mod.py"], root=tmp_path, runner=runner)
        assert len(findings) == 1
        finding = findings[0]
        assert finding["tool"] == "mypy"
        assert finding["rule_id"] == "return-value"
        assert finding["category"] == "type-error"
        assert finding["line"] == 4
        assert finding["end_line"] == 4

    def test_mypy_sarif_payload_shape(self, tmp_path):
        records = [json.loads(MYPY_LINE)]
        payload = mypy_records_to_sarif(records, root=tmp_path)
        assert payload["version"] == "2.1.0"
        driver = payload["runs"][0]["tool"]["driver"]
        assert driver["name"] == "mypy"
        assert driver["rules"][0]["id"] == "return-value"
        parsed = parse_sarif_payload(payload)
        assert len(parsed) == 1
        assert parsed[0]["tool"] == "mypy"
        assert parsed[0]["rule_id"] == "return-value"

    def test_unsupported_files_skipped(self, tmp_path):
        def exploding_runner(argv, **_kwargs):  # pragma: no cover
            raise AssertionError("runner must not be called")

        assert (
            collect_lint_findings(
                ["README.md", "logo.png"], root=tmp_path, runner=exploding_runner
            )
            == []
        )

    def test_timeout_reports_to_sentry_and_does_not_crash(
        self, tmp_path, sentry_calls
    ):
        def timeout_runner(argv, **_kwargs):
            raise subprocess.TimeoutExpired(argv, 60)

        findings = collect_lint_findings(
            ["a.py"], root=tmp_path, timeout=1, runner=timeout_runner
        )
        assert findings == []
        assert len(sentry_calls) == 2  # one per tool
        assert all(
            isinstance(exc, subprocess.TimeoutExpired) for exc in sentry_calls
        )

    def test_missing_tool_reports_to_sentry(self, tmp_path, sentry_calls):
        def missing_runner(argv, **_kwargs):
            raise FileNotFoundError(argv[0])

        findings = collect_lint_findings(["a.py"], root=tmp_path, runner=missing_runner)
        assert findings == []
        assert len(sentry_calls) == 2

    def test_fatal_exit_code_reports_to_sentry(self, tmp_path, sentry_calls):
        runner = _runner(ruff_stdout="", ruff_rc=2, mypy_stdout="", mypy_rc=2)
        findings = collect_lint_findings(["a.py"], root=tmp_path, runner=runner)
        assert findings == []
        assert len(sentry_calls) == 2
        assert all(isinstance(exc, RuntimeError) for exc in sentry_calls)


class TestSarifBridge:
    def test_build_sarif_payload_round_trips(self):
        findings = [
            {
                "tool": "ruff",
                "rule_id": "F401",
                "category": "unused-import",
                "severity": "HIGH",
                "message": "unused",
                "path": "pkg/mod.py",
                "line": 3,
                "end_line": 3,
                "cwe_ids": [],
                "taint_path": [],
            },
            {
                "tool": "mypy",
                "rule_id": "return-value",
                "category": "type-error",
                "severity": "HIGH",
                "message": "bad return",
                "path": "pkg/mod.py",
                "line": 9,
                "end_line": 9,
                "cwe_ids": [],
                "taint_path": [],
            },
        ]
        payload = build_sarif_payload(findings)
        parsed = parse_sarif_payload(payload)
        assert {(p["tool"], p["rule_id"], p["path"], p["line"]) for p in parsed} == {
            ("ruff", "F401", "pkg/mod.py", 3),
            ("mypy", "return-value", "pkg/mod.py", 9),
        }


class TestRuleCategory:
    def test_categories(self):
        assert rule_category("ruff", "F401") == "unused-import"
        assert rule_category("ruff", "F841") == "unused-variable"
        assert rule_category("ruff", "E501") == "ruff-e"
        assert rule_category("mypy", "return-value") == "type-error"
        assert rule_category("mypy", "arg-type") == "type-error"


def _finding(**overrides):
    base = {
        "tool": "ruff",
        "rule_id": "F401",
        "category": "unused-import",
        "path": "pkg/mod.py",
        "line": 10,
        "end_line": 12,
    }
    base.update(overrides)
    return base


def _comment(**overrides):
    base = {
        "path": "pkg/mod.py",
        "line": 11,
        "category": "unused-import",
        "message": "This import is unused.",
    }
    base.update(overrides)
    return base


class TestDedupe:
    def test_overlap_same_category_dropped(self):
        kept, dropped = dedupe_review_comments([_comment()], [_finding()])
        assert kept == []
        assert len(dropped) == 1

    def test_different_line_kept(self):
        kept, dropped = dedupe_review_comments(
            [_comment(line=40)], [_finding()]
        )
        assert len(kept) == 1
        assert dropped == []

    def test_different_category_kept(self):
        kept, dropped = dedupe_review_comments(
            [_comment(category="security")], [_finding()]
        )
        assert len(kept) == 1
        assert dropped == []

    def test_different_file_kept(self):
        kept, dropped = dedupe_review_comments(
            [_comment(path="pkg/other.py")], [_finding()]
        )
        assert len(kept) == 1
        assert dropped == []

    def test_comment_rule_id_derives_category(self):
        comment = _comment()
        del comment["category"]
        comment["rule_id"] = "F401"
        kept, dropped = dedupe_review_comments([comment], [_finding()])
        assert kept == []
        assert len(dropped) == 1

    def test_comment_without_category_or_rule_kept(self):
        comment = {"path": "pkg/mod.py", "line": 11, "message": "vague"}
        kept, dropped = dedupe_review_comments([comment], [_finding()])
        assert len(kept) == 1
        assert dropped == []

    def test_touching_ranges_overlap(self):
        kept, dropped = dedupe_review_comments(
            [_comment(line=12)], [_finding()]
        )
        assert kept == []
        assert len(dropped) == 1


class _FakeNeo4j:
    def __init__(self):
        self.writes: list[tuple[str, dict]] = []

    def execute_write(self, query, params):
        self.writes.append((query, params))
        return []


class TestIngestGate:
    def test_disabled_by_default(self, tmp_path, monkeypatch):
        import backend.config as config_module

        monkeypatch.setattr(
            config_module,
            "get_config",
            lambda: SimpleNamespace(
                lint_findings_enabled=False, lint_timeout_sec=5
            ),
        )

        def exploding_runner(argv, **_kwargs):  # pragma: no cover
            raise AssertionError("runner must not be called when disabled")

        result = ingest_lint_findings(
            _FakeNeo4j(), ["a.py"], root=tmp_path, runner=exploding_runner
        )
        assert result == {"enabled": False, "findings": 0, "findings_written": 0}

    def test_enabled_writes_through_sarif_path(self, tmp_path, monkeypatch):
        import backend.config as config_module

        monkeypatch.setattr(
            config_module,
            "get_config",
            lambda: SimpleNamespace(lint_findings_enabled=True, lint_timeout_sec=5),
        )
        runner = _runner(ruff_stdout=json.dumps(RUFF_SARIF), mypy_stdout="")
        client = _FakeNeo4j()
        result = ingest_lint_findings(client, ["pkg/mod.py"], root=tmp_path, runner=runner)
        assert result["enabled"] is True
        assert result["findings"] == 1
        assert result["findings_written"] == 1
        assert client.writes  # SecurityFinding MERGE went through write_sarif_findings

    def test_mypy_safe_mode_passes_dev_null_config(self, tmp_path):
        seen_argvs: list[list[str]] = []

        def recording_runner(argv, **_kwargs):
            seen_argvs.append(list(argv))
            return _completed(argv, stdout="", returncode=0)

        collect_lint_findings(["pkg/mod.py"], root=tmp_path, runner=recording_runner)
        mypy_argv = next(a for a in seen_argvs if a[0] == "mypy")
        assert "--config-file=/dev/null" in mypy_argv
        assert "--follow-imports=silent" in mypy_argv


@pytest.mark.skipif(
    shutil.which("ruff") is None and not shutil.which("mypy"),
    reason="lint tools not installed",
)
def test_real_tools_end_to_end(tmp_path):
    target = tmp_path / "bad.py"
    target.write_text("import os\n\n\ndef f() -> int:\n    return 's'\n", encoding="utf-8")
    findings = collect_lint_findings(["bad.py"], root=tmp_path, timeout=120)
    tools = {f["tool"] for f in findings}
    assert "ruff" in tools  # F401 unused import of os
    assert any(f["rule_id"] == "F401" for f in findings)


class TestLanguageAgnosticLinters:
    def test_dart_analyze_json_converted_to_sarif_findings(self, tmp_path):
        dart_payload = {
            "version": 1,
            "diagnostics": [
                {
                    "code": "unused_import",
                    "severity": "WARNING",
                    "type": "STATIC_WARNING",
                    "location": {
                        "file": str(tmp_path / "lib/main.dart"),
                        "range": {
                            "start": {"line": 2, "column": 8},
                            "end": {"line": 2, "column": 24},
                        },
                    },
                    "problemMessage": "Unused import: 'dart:math'.",
                },
                {
                    "code": "invalid_assignment",
                    "severity": "ERROR",
                    "type": "COMPILE_TIME_ERROR",
                    "location": {
                        "file": str(tmp_path / "lib/main.dart"),
                        "range": {
                            "start": {"line": 5, "column": 11},
                            "end": {"line": 5, "column": 15},
                        },
                    },
                    "problemMessage": "A value of type 'String' can't be assigned to 'int'.",
                },
            ],
        }

        def run(argv, **_kwargs):
            assert argv[:3] == ["dart", "analyze", "--format"]
            return _completed(argv, stdout=json.dumps(dart_payload), returncode=3)

        findings = collect_lint_findings(["lib/main.dart"], root=tmp_path, runner=run)
        assert len(findings) == 2
        assert findings[0]["tool"] == "dart"
        assert findings[0]["rule_id"] == "unused_import"
        assert findings[0]["category"] == "unused-import"
        assert findings[0]["severity"] == "MEDIUM"
        assert findings[0]["path"] == "lib/main.dart"
        assert findings[0]["line"] == 2
        assert findings[1]["rule_id"] == "invalid_assignment"
        assert findings[1]["category"] == "type-error"
        assert findings[1]["severity"] == "HIGH"

    def test_eslint_json_converted_to_sarif_findings(self, tmp_path):
        eslint_payload = [
            {
                "filePath": str(tmp_path / "src/app.ts"),
                "messages": [
                    {
                        "ruleId": "no-unused-vars",
                        "severity": 1,
                        "message": "'x' is assigned a value but never used.",
                        "line": 7,
                        "endLine": 7,
                    }
                ],
            }
        ]

        def run(argv, **_kwargs):
            assert argv[:3] == ["eslint", "--format", "json"]
            return _completed(argv, stdout=json.dumps(eslint_payload), returncode=1)

        findings = collect_lint_findings(["src/app.ts"], root=tmp_path, runner=run)
        assert len(findings) == 1
        assert findings[0]["tool"] == "eslint"
        assert findings[0]["rule_id"] == "no-unused-vars"
        assert findings[0]["category"] == "unused-variable"
        assert findings[0]["severity"] == "MEDIUM"
        assert findings[0]["path"] == "src/app.ts"
        assert findings[0]["line"] == 7

    def test_missing_optional_non_python_tool_degrades_gracefully(self, tmp_path, sentry_calls):
        def run(argv, **_kwargs):
            raise FileNotFoundError(argv[0])

        findings = collect_lint_findings(
            ["lib/main.dart", "src/app.ts"], root=tmp_path, runner=run
        )
        assert findings == []
        assert sentry_calls == []

    def test_dedupe_works_for_dart_findings(self):
        findings = [
            {
                "tool": "dart",
                "rule_id": "unused_import",
                "category": "unused-import",
                "path": "lib/main.dart",
                "line": 2,
                "end_line": 2,
            }
        ]
        comments = [
            {
                "path": "lib/main.dart",
                "line": 2,
                "category": "unused-import",
                "body": "Remove unused import.",
            }
        ]
        kept, dropped = dedupe_review_comments(comments, findings)
        assert kept == []
        assert len(dropped) == 1

    def test_rule_category_supports_dart_and_eslint(self):
        assert rule_category("dart", "unused_import") == "unused-import"
        assert rule_category("dart", "invalid_assignment") == "type-error"
        assert rule_category("eslint", "@typescript-eslint/no-unused-vars") == "unused-variable"
