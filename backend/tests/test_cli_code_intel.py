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
    assert kwargs["timeout"] == 300


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
    assert mock.call_args.kwargs["timeout"] == 120


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


def test_xray_symbol_marks_unresolved(capsys):
    ret = {"symbols": [
        {"name": "main", "qualified_name": "veraxi.cli.main", "label": "CodeModule",
         "path": "packages/veraxi-cli/src/veraxi/cli/main.py", "line": 1, "resolved": True},
        {"name": "ext", "qualified_name": "ext.mod", "label": "CodeModule",
         "path": "", "line": 0, "resolved": False},
    ]}
    with patch(PATCH_TARGET, return_value=ret), pytest.raises(SystemExit):
        run_xray_symbol("main")
    out = capsys.readouterr().out
    assert "[external/unresolved]" in out
    assert "veraxi.cli.main" in out


def test_xray_symbol_resolved_only_filters(capsys):
    from veraxi.cli.code_intel import run_xray_symbol as _symbol

    ret = {"symbols": [
        {"name": "main", "qualified_name": "veraxi.cli.main", "label": "CodeModule",
         "path": "m.py", "line": 1, "resolved": True},
        {"name": "ext", "qualified_name": "ext.mod", "label": "CodeModule",
         "path": "", "line": 0, "resolved": False},
    ]}
    with patch(PATCH_TARGET, return_value=ret), pytest.raises(SystemExit):
        _symbol("main", resolved_only=True)
    out = capsys.readouterr().out
    assert "veraxi.cli.main" in out
    assert "ext.mod" not in out


def test_xray_index_local_parses_and_uploads(tmp_path):
    from veraxi.cli.code_intel import run_xray_index as _index

    pkg = tmp_path / "packages" / "veraxi-cli" / "src" / "veraxi" / "cli"
    pkg.mkdir(parents=True)
    (pkg / "main.py").write_text("def main():\n    return 1\n", encoding="utf-8")
    (pkg / "__init__.py").write_text("", encoding="utf-8")
    with patch(PATCH_TARGET, return_value={"status": "ok", "nodes_written": 4, "edges_written": 2}) as mock, pytest.raises(SystemExit) as exc:
        _index(str(tmp_path), local=True)
    assert exc.value.code == 0
    args, kwargs = mock.call_args
    assert args[1] == "/api/v1/code/ingest-graph"
    body = kwargs["body"]
    qns = {n["qualified_name"] for n in body["nodes"]}
    assert "veraxi.cli.main" in qns
    assert "veraxi.cli.main.main" in qns
    main_node = next(n for n in body["nodes"] if n["qualified_name"] == "veraxi.cli.main")
    assert main_node["path"] == "packages/veraxi-cli/src/veraxi/cli/main.py"
