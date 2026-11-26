"""CLI tests for `veraxi review --structured` / `--with-lint` (WP5)."""

from __future__ import annotations

import json
import subprocess
from unittest.mock import patch

from veraxi.cli.review import _extract_diff_files, run_review

PATCH_API = "veraxi.cli.http_client.api_request"

SAMPLE_DIFF = (
    "diff --git a/pkg/mod.py b/pkg/mod.py\n"
    "--- a/pkg/mod.py\n"
    "+++ b/pkg/mod.py\n"
    "@@ -1,2 +1,3 @@\n"
    "+import os\n"
    " def f():\n"
    "     return 1\n"
    "diff --git a/old.py b/old.py\n"
    "--- a/old.py\n"
    "+++ /dev/null\n"
)

SAMPLE_RUFF_SARIF = {
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


def test_extract_diff_files_skips_deleted_and_dedupes():
    diff = SAMPLE_DIFF + "\n+++ b/pkg/mod.py\n"
    assert _extract_diff_files(diff) == ["pkg/mod.py"]


def test_structured_review_posts_diff_and_prints_summary(capsys):
    api_response = {
        "status": "ok",
        "comments": [
            {
                "path": "pkg/mod.py",
                "line": 3,
                "severity": "HIGH",
                "category": "bug",
                "message": "Unhandled None return",
            }
        ],
        "dropped_duplicates": [{"path": "pkg/mod.py", "line": 1, "category": "unused-import"}],
        "summary": {
            "files_count": 1,
            "lint_finding_count": 1,
            "dedupe_drop_rate": 0.5,
        },
    }

    def fake_git(argv, **_kwargs):
        return subprocess.CompletedProcess(argv, 0, stdout=SAMPLE_DIFF, stderr="")

    with (
        patch("veraxi.cli.review.subprocess.run", side_effect=fake_git),
        patch(PATCH_API, return_value=api_response) as mock_api,
    ):
        run_review(
            staged=True,
            project="acme/repo",
            tenant_id="t1",
            endpoint="https://api.veraxi.me/sse",
            key="vx-k",
            structured=True,
        )

    args, kwargs = mock_api.call_args
    assert args == ("POST", "/api/v1/code/review")
    assert kwargs["body"]["files"] == ["pkg/mod.py"]
    assert kwargs["body"]["repo"] == "acme/repo"
    assert "lint_sarif" not in kwargs["body"]
    out = capsys.readouterr().out
    assert "1 file(s), 1 lint finding(s), 1 AI comment(s) kept, 1 duplicate(s) dropped" in out
    assert "[HIGH bug] pkg/mod.py:3" in out


def test_with_lint_attaches_local_ruff_sarif_and_json_output(capsys):
    api_response = {
        "status": "ok",
        "comments": [],
        "dropped_duplicates": [],
        "summary": {"files_count": 1, "lint_finding_count": 1, "dedupe_drop_rate": 1.0},
    }

    def fake_subprocess(argv, **_kwargs):
        if argv[0] == "git":
            return subprocess.CompletedProcess(argv, 0, stdout=SAMPLE_DIFF, stderr="")
        if argv[0] == "ruff":
            return subprocess.CompletedProcess(
                argv, 1, stdout=json.dumps(SAMPLE_RUFF_SARIF), stderr=""
            )
        raise AssertionError(f"unexpected command: {argv}")

    with (
        patch("veraxi.cli.review.shutil.which", return_value="/usr/bin/ruff"),
        patch("veraxi.cli.review.subprocess.run", side_effect=fake_subprocess),
        patch(PATCH_API, return_value=api_response) as mock_api,
    ):
        run_review(with_lint=True, as_json=True)

    body = mock_api.call_args.kwargs["body"]
    assert body["lint_sarif"]["runs"][0]["tool"]["driver"]["name"] == "ruff"
    parsed_out = json.loads(capsys.readouterr().out)
    assert parsed_out["summary"]["dedupe_drop_rate"] == 1.0
