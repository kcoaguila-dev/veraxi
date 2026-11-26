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


def test_xray_index_local_skips_venv_and_caches(tmp_path):
    from veraxi.cli.code_intel import parse_repo_locally

    (tmp_path / "app.py").write_text("def hello():\n    return 'hi'\n", encoding="utf-8")
    for ignored in (".venv/lib/python3.12/site-packages", "venv/lib", ".pytest_cache", "node_modules/pkg"):
        d = tmp_path / ignored
        d.mkdir(parents=True)
        (d / "ignored.py").write_text("def noise():\n    pass\n", encoding="utf-8")
    payload = parse_repo_locally(str(tmp_path))
    paths = {n["path"] for n in payload["nodes"]}
    assert paths == {"app.py"}


def test_vuln_report_live_osv_flag(tmp_path):
    deps = tmp_path / "deps.json"
    deps.write_text(json.dumps([{"name": "requests", "version": "2.31.0"}]), encoding="utf-8")
    with patch(PATCH_TARGET, return_value=_report("high")) as mock, pytest.raises(SystemExit) as exc:
        run_vuln_report(deps=str(deps), live_osv=True)
    assert exc.value.code == 0
    assert mock.call_args.kwargs["body"] == {
        "dependencies": [{"name": "requests", "version": "2.31.0"}],
        "live_osv": True,
    }


def test_vuln_report_local_extracts_deps_and_posts(tmp_path):
    (tmp_path / "pyproject.toml").write_text(
        '[project]\nname = "demo"\ndependencies = ["requests==2.31.0"]\n',
        encoding="utf-8",
    )
    venv_dir = tmp_path / ".venv" / "lib"
    venv_dir.mkdir(parents=True)
    (venv_dir / "pyproject.toml").write_text(
        '[project]\nname = "ignored"\ndependencies = ["evil==0.0.1"]\n',
        encoding="utf-8",
    )
    with patch(PATCH_TARGET, return_value=_report("low")) as mock, pytest.raises(SystemExit) as exc:
        run_vuln_report(repo_path=str(tmp_path), local=True, live_osv=True)
    assert exc.value.code == 0
    body = mock.call_args.kwargs["body"]
    assert body["live_osv"] is True
    assert body["dependencies"] == [
        {"name": "requests", "version": "2.31.0", "ecosystem": "pypi", "source_file": "pyproject.toml"}
    ]


def test_vuln_report_local_parses_uv_lock_and_package_lock(tmp_path):
    from veraxi.cli.code_intel import extract_deps_locally

    (tmp_path / "uv.lock").write_text(
        '[[package]]\nname = "urllib3"\nversion = "2.2.0"\nsource = { registry = "https://pypi.org/simple" }\n'
        '[[package]]\nname = "veraxi"\nversion = "0.1.0"\nsource = { editable = "." }\n',
        encoding="utf-8",
    )
    (tmp_path / "package-lock.json").write_text(
        json.dumps({"packages": {"": {"name": "app"}, "node_modules/lodash": {"version": "4.17.21"}}}),
        encoding="utf-8",
    )
    deps = extract_deps_locally(str(tmp_path))
    assert deps == [
        {"name": "lodash", "version": "4.17.21", "ecosystem": "npm", "source_file": "package-lock.json"},
        {"name": "urllib3", "version": "2.2.0", "ecosystem": "pypi", "source_file": "uv.lock"},
    ]


def test_vuln_sarif_and_sbom_cli(tmp_path):
    from veraxi.cli.code_intel import run_vuln_report, run_vuln_sarif

    sarif_file = tmp_path / "semgrep.sarif"
    sarif_file.write_text(json.dumps({"version": "2.1.0", "runs": []}), encoding="utf-8")
    with patch(
        PATCH_TARGET,
        return_value={"status": "ok", "findings_written": 1, "file_links": 1, "cwe_links": 1},
    ) as mock, pytest.raises(SystemExit) as exc:
        run_vuln_sarif(str(sarif_file))
    assert exc.value.code == 0
    assert mock.call_args.args[:2] == ("POST", "/api/v1/vuln/sarif")

    sbom_file = tmp_path / "bom.json"
    sbom_file.write_text(json.dumps({"bomFormat": "CycloneDX", "components": []}), encoding="utf-8")
    with patch(PATCH_TARGET, return_value=_report("low")) as mock, pytest.raises(SystemExit) as exc:
        run_vuln_report(sbom=str(sbom_file), reachability=True)
    assert exc.value.code == 0
    body = mock.call_args.kwargs["body"]
    assert body["sbom_json"]["bomFormat"] == "CycloneDX"
    assert body["include_reachability"] is True


def test_xray_index_scip_posts_payload(tmp_path, capsys):
    from veraxi.cli.code_intel import run_xray_index_scip

    scip_file = tmp_path / "index.scip.json"
    payload = {"documents": [{"relative_path": "a.py", "symbols": [], "occurrences": []}]}
    scip_file.write_text(json.dumps(payload), encoding="utf-8")
    with patch(
        PATCH_TARGET,
        return_value={"status": "ok", "nodes_written": 3, "edges_written": 2},
    ) as mock, pytest.raises(SystemExit) as exc:
        run_xray_index_scip(str(scip_file), endpoint="https://api.veraxi.me/sse", key="vx-k", tenant="t1")
    assert exc.value.code == 0
    args, kwargs = mock.call_args
    assert args[:2] == ("POST", "/api/v1/code/ingest-scip")
    assert kwargs["body"] == {"scip": payload}
    assert kwargs["timeout"] == 300
    assert "nodes=3 edges=2" in capsys.readouterr().out


def test_xray_index_scip_rejects_invalid_json(tmp_path):
    from veraxi.cli.code_intel import run_xray_index_scip

    bad = tmp_path / "bad.scip.json"
    bad.write_text("{not json", encoding="utf-8")
    with pytest.raises(SystemExit) as exc:
        run_xray_index_scip(str(bad))
    assert exc.value.code == 1


def test_vuln_attack_sync_and_recon_cli(tmp_path):
    from veraxi.cli.code_intel import run_vuln_attack_sync, run_vuln_recon

    with patch(
        PATCH_TARGET,
        return_value={"status": "ok", "techniques_written": 1},
    ) as mock, pytest.raises(SystemExit) as exc:
        run_vuln_attack_sync()
    assert exc.value.code == 0
    assert mock.call_args.args[:2] == ("POST", "/api/v1/vuln/attack/sync")

    nuclei_file = tmp_path / "nuclei.jsonl"
    nuclei_file.write_text('{"template-id":"test","matched-at":"https://x.test"}\n', encoding="utf-8")
    with patch(
        PATCH_TARGET,
        return_value={"status": "ok", "findings_written": 1, "host_links": 1, "cve_links": 0},
    ) as mock, pytest.raises(SystemExit) as exc:
        run_vuln_recon(str(nuclei_file))
    assert exc.value.code == 0
    assert mock.call_args.args[:2] == ("POST", "/api/v1/vuln/recon")
