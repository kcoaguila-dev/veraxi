"""CLI tests for xray/vuln (WP2) with mocked HTTP."""
import json
from unittest.mock import patch

import pytest
from veraxi.cli.code_intel import run_vuln_report, run_vuln_sync, run_xray_index, run_xray_symbol

PATCH_TARGET = "veraxi.cli.http_client.api_request"


def test_xray_index_posts_repo_path():
    ret = {"status": "ok", "repo_path": "/app/repo", "files": 3}
    with patch(PATCH_TARGET, return_value=ret) as mock, pytest.raises(SystemExit) as exc:
        run_xray_index("/app/repo", endpoint="https://api.veraxi.me/sse", key="vx-k", tenant="t1")
    assert exc.value.code == 0
    args, kwargs = mock.call_args
    assert args[0] == "POST" and args[1] == "/api/v1/code/ingest"
    assert kwargs["body"] == {"repo_path": "/app/repo"}


def test_xray_symbol_query_param():
    ret = {"symbols": [{"name": "foo", "qualified_name": "m.foo", "label": "Function", "path": "m.py", "line": 1}]}
    with patch(PATCH_TARGET, return_value=ret) as mock, pytest.raises(SystemExit) as exc:
        run_xray_symbol("foo")
    assert exc.value.code == 0
    assert mock.call_args.kwargs["params"] == {"name": "foo"}


def test_vuln_sync_posts():
    with patch(PATCH_TARGET, return_value={"status": "ok", "cves": 10}) as mock, pytest.raises(SystemExit) as exc:
        run_vuln_sync()
    assert exc.value.code == 0
    assert mock.call_args.args[1] == "/api/v1/vuln/sync"


def _report(severity):
    return {"dependencies_checked": 1, "matched_count": 1, "unknown_count": 0, "kev_count": 0,
            "findings": [{"severity": severity, "cve_id": "CVE-1", "package": "pkg", "version": "1.0", "match_status": "matched"}]}


def test_vuln_report_fail_on_high_gates_critical():
    with patch(PATCH_TARGET, return_value=_report("critical")), pytest.raises(SystemExit) as exc:
        run_vuln_report(repo_path="/app/repo", fail_on="high")
    assert exc.value.code == 2


def test_vuln_report_fail_on_critical_passes_high():
    with patch(PATCH_TARGET, return_value=_report("high")), pytest.raises(SystemExit) as exc:
        run_vuln_report(repo_path="/app/repo", fail_on="critical")
    assert exc.value.code == 0


def test_vuln_report_deps_file(tmp_path):
    deps = tmp_path / "deps.json"
    deps.write_text(json.dumps([{"name": "pkg", "version": "1.0"}]), encoding="utf-8")
    with patch(PATCH_TARGET, return_value=_report("low")) as mock, pytest.raises(SystemExit) as exc:
        run_vuln_report(deps=str(deps))
    assert exc.value.code == 0
    assert mock.call_args.kwargs["body"] == {"dependencies": [{"name": "pkg", "version": "1.0"}]}


def test_allowlist_rejection_surfaced():
    # http_client exits 1 with the server detail; run_xray_index must not swallow it.
    with patch(PATCH_TARGET, side_effect=SystemExit(1)), pytest.raises(SystemExit) as exc:
        run_xray_index("/etc/passwd")
    assert exc.value.code == 1
