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


def test_api_request_gzip_body_round_trips(monkeypatch):
    """gzip_body=True sends a gzipped JSON body with Content-Encoding:
    gzip, and the bytes decompress back to the exact original payload."""
    import gzip

    from veraxi.cli import http_client

    captured = {}

    class _Resp:
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return b'{"status": "ok"}'

    def fake_urlopen(req, timeout=None):
        captured["data"] = req.data
        captured["headers"] = {k.lower(): v for k, v in req.header_items()}
        return _Resp()

    monkeypatch.setattr(http_client.urllib.request, "urlopen", fake_urlopen)
    body = {"scip": {"documents": [{"relative_path": "a.py"}]}, "repo_key": "o/r"}
    out = http_client.api_request(
        "POST", "/api/v1/code/ingest-scip", body=body, gzip_body=True
    )
    assert out == {"status": "ok"}
    assert captured["headers"]["content-encoding"] == "gzip"
    assert json.loads(gzip.decompress(captured["data"])) == body
    # The compressed form must actually be smaller for a repetitive payload.
    big = {"scip": {"documents": [{"relative_path": "a.py", "symbols": ["x" * 64] * 50}]}}
    http_client.api_request("POST", "/api/v1/code/ingest-scip", body=big, gzip_body=True)
    assert len(captured["data"]) < len(json.dumps(big))


def test_xray_index_scip_rejects_invalid_json(tmp_path):
    from veraxi.cli.code_intel import run_xray_index_scip

    bad = tmp_path / "bad.scip.json"
    bad.write_text("{not json", encoding="utf-8")
    with pytest.raises(SystemExit) as exc:
        run_xray_index_scip(str(bad))
    assert exc.value.code == 1


def test_xray_index_generate_scip_runs_tools_and_uploads(tmp_path, monkeypatch):
    """ADR-0007 Phase 4: generation runs scip-python + scip print
    locally (argument lists, --project-version always passed), then
    uploads through the existing ingest-scip path."""
    import subprocess as sp

    from veraxi.cli import code_intel as cli_mod
    from veraxi.cli.code_intel import run_xray_index_generate_scip

    repo = tmp_path / "demo"
    repo.mkdir()
    (repo / "mod.py").write_text("def f():\n    pass\n", encoding="utf-8")
    monkeypatch.setenv("VERAXI_SCIP_PYTHON_BIN", "/tools/scip-python")
    monkeypatch.setenv("VERAXI_SCIP_BIN", "/tools/scip")
    calls = []

    def fake_run(argv, **kwargs):
        calls.append(argv)
        if argv[0] == "/tools/scip-python":
            # The --output target must be created, as the real tool does.
            out = argv[argv.index("--output") + 1]
            with open(out, "wb") as fh:
                fh.write(b"fake-index")
            return sp.CompletedProcess(argv, 0, stdout="", stderr="")
        if argv[0] == "/tools/scip":
            payload = {"documents": [], "metadata": {"projectRoot": "file:///demo"}}
            return sp.CompletedProcess(argv, 0, stdout=json.dumps(payload), stderr="")
        return sp.CompletedProcess(argv, 1, stdout="", stderr="")  # git: no HEAD

    monkeypatch.setattr(cli_mod.subprocess, "run", fake_run)
    with patch(
        PATCH_TARGET, return_value={"status": "ok", "nodes_written": 1, "edges_written": 0}
    ) as mock, pytest.raises(SystemExit) as exc:
        run_xray_index_generate_scip(
            str(repo), endpoint="https://api.veraxi.me/sse", key="vx-k", tenant="t1"
        )
    assert exc.value.code == 0
    index_argv = next(a for a in calls if a[0] == "/tools/scip-python")
    assert index_argv[1] == "index"
    assert "--project-version" in index_argv  # non-git fallback, never omitted
    assert index_argv[index_argv.index("--project-version") + 1] == "0.0.0"
    print_argv = next(a for a in calls if a[0] == "/tools/scip")
    assert print_argv[1:3] == ["print", "--json"]
    args, kwargs = mock.call_args
    assert args[:2] == ("POST", "/api/v1/code/ingest-scip")
    assert kwargs["body"]["scip"]["documents"] == []


def test_xray_index_generate_scip_missing_tools_exit_1(tmp_path, monkeypatch):
    from veraxi.cli.code_intel import run_xray_index_generate_scip

    monkeypatch.delenv("VERAXI_SCIP_PYTHON_BIN", raising=False)
    monkeypatch.delenv("VERAXI_SCIP_BIN", raising=False)
    monkeypatch.setenv("PATH", str(tmp_path))  # empty PATH: tools not found
    with pytest.raises(SystemExit) as exc:
        run_xray_index_generate_scip(str(tmp_path))
    assert exc.value.code == 1


def test_xray_index_generate_scip_indexer_failure_exit_1(tmp_path, monkeypatch):
    import subprocess as sp

    from veraxi.cli import code_intel as cli_mod
    from veraxi.cli.code_intel import run_xray_index_generate_scip

    monkeypatch.setenv("VERAXI_SCIP_PYTHON_BIN", "/tools/scip-python")
    monkeypatch.setenv("VERAXI_SCIP_BIN", "/tools/scip")

    def failing_run(argv, **kwargs):
        return sp.CompletedProcess(argv, 2, stdout="", stderr="boom")

    monkeypatch.setattr(cli_mod.subprocess, "run", failing_run)
    with pytest.raises(SystemExit) as exc:
        run_xray_index_generate_scip(str(tmp_path))
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


def test_derive_repo_key_from_git_origin_https_and_ssh(tmp_path, monkeypatch):
    import subprocess as sp

    from veraxi.cli import code_intel as cli_mod
    from veraxi.cli.code_intel import _derive_repo_key

    for url in ("https://github.com/owner/repo.git\n", "git@github.com:owner/repo.git\n"):
        def fake_run(argv, _url=url, **kw):
            return sp.CompletedProcess(argv, 0, stdout=_url, stderr="")

        monkeypatch.setattr(cli_mod.subprocess, "run", fake_run)
        assert _derive_repo_key(str(tmp_path)) == "owner/repo"


def test_derive_repo_key_falls_back_to_resolved_path(tmp_path, monkeypatch):
    import subprocess as sp

    from veraxi.cli import code_intel as cli_mod
    from veraxi.cli.code_intel import _derive_repo_key

    monkeypatch.setattr(
        cli_mod.subprocess, "run",
        lambda argv, **kw: sp.CompletedProcess(argv, 1, stdout="", stderr="no remote"),
    )
    assert _derive_repo_key(str(tmp_path)) == str(tmp_path.resolve())


def test_xray_index_generate_scip_includes_repo_key_from_origin(tmp_path, monkeypatch):
    import subprocess as sp

    from veraxi.cli import code_intel as cli_mod
    from veraxi.cli.code_intel import run_xray_index_generate_scip

    repo = tmp_path / "repo"
    repo.mkdir()
    monkeypatch.setenv("VERAXI_SCIP_PYTHON_BIN", "/tools/scip-python")
    monkeypatch.setenv("VERAXI_SCIP_BIN", "/tools/scip")

    def fake_run(argv, **kwargs):
        if argv[0] == "/tools/scip-python":
            out = argv[argv.index("--output") + 1]
            with open(out, "wb") as fh:
                fh.write(b"fake-index")
            return sp.CompletedProcess(argv, 0, stdout="", stderr="")
        if argv[0] == "/tools/scip":
            return sp.CompletedProcess(argv, 0, stdout=json.dumps({"documents": []}), stderr="")
        if "remote" in argv:  # git remote get-url origin
            return sp.CompletedProcess(argv, 0, stdout="https://github.com/owner/repo.git\n", stderr="")
        if "rev-parse" in argv:
            return sp.CompletedProcess(argv, 0, stdout="abc123\n", stderr="")
        return sp.CompletedProcess(argv, 1, stdout="", stderr="")

    monkeypatch.setattr(cli_mod.subprocess, "run", fake_run)
    with patch(
        PATCH_TARGET, return_value={"status": "ok", "nodes_written": 1, "edges_written": 0}
    ) as mock, pytest.raises(SystemExit) as exc:
        run_xray_index_generate_scip(str(repo))
    assert exc.value.code == 0
    assert mock.call_args.kwargs["body"]["repo_key"] == "owner/repo"


def test_xray_index_generate_scip_dart_auto_detect_and_upload(tmp_path, monkeypatch):
    import subprocess as sp

    from veraxi.cli import code_intel as cli_mod
    from veraxi.cli.code_intel import run_xray_index_generate_scip

    repo = tmp_path / "dart_repo"
    (repo / ".dart_tool").mkdir(parents=True)
    (repo / "pubspec.yaml").write_text("name: sample_app\n", encoding="utf-8")
    (repo / ".dart_tool" / "package_config.json").write_text("{}", encoding="utf-8")
    monkeypatch.setenv("VERAXI_SCIP_DART_BIN", "/tools/scip_dart")
    monkeypatch.setenv("VERAXI_SCIP_BIN", "/tools/scip")

    seen_cmds = []

    def fake_run(argv, **kwargs):
        seen_cmds.append(argv)
        if argv[0] == "/tools/scip_dart":
            out = argv[argv.index("-o") + 1]
            with open(out, "wb") as fh:
                fh.write(b"fake-dart-index")
            return sp.CompletedProcess(argv, 0, stdout="", stderr="")
        if argv[0] == "/tools/scip":
            return sp.CompletedProcess(
                argv, 0, stdout=json.dumps({"documents": [{"relativePath": "lib/main.dart"}]}), stderr=""
            )
        if "remote" in argv:
            return sp.CompletedProcess(argv, 0, stdout="https://github.com/owner/dart_repo.git\n", stderr="")
        return sp.CompletedProcess(argv, 1, stdout="", stderr="")

    monkeypatch.setattr(cli_mod.subprocess, "run", fake_run)
    with patch(
        PATCH_TARGET, return_value={"status": "ok", "nodes_written": 2, "edges_written": 1}
    ) as mock, pytest.raises(SystemExit) as exc:
        run_xray_index_generate_scip(str(repo))
    assert exc.value.code == 0
    assert any(cmd[0] == "/tools/scip_dart" for cmd in seen_cmds)
    assert mock.call_args.kwargs["body"]["repo_key"] == "owner/dart_repo"


def test_xray_index_generate_scip_dart_missing_package_config_exit_1(tmp_path, monkeypatch, capsys):
    from veraxi.cli.code_intel import run_xray_index_generate_scip

    repo = tmp_path / "dart_repo"
    repo.mkdir()
    (repo / "pubspec.yaml").write_text("name: sample_app\n", encoding="utf-8")
    monkeypatch.setenv("VERAXI_SCIP_DART_BIN", "/tools/scip_dart")
    monkeypatch.setenv("VERAXI_SCIP_BIN", "/tools/scip")

    with pytest.raises(SystemExit) as exc:
        run_xray_index_generate_scip(str(repo), lang="dart")
    assert exc.value.code == 1
    assert "pub get" in capsys.readouterr().err


def test_xray_index_generate_scip_dart_missing_tools_exit_1(tmp_path, monkeypatch, capsys):
    from veraxi.cli import code_intel as cli_mod
    from veraxi.cli.code_intel import run_xray_index_generate_scip

    repo = tmp_path / "dart_repo"
    (repo / ".dart_tool").mkdir(parents=True)
    (repo / "pubspec.yaml").write_text("name: sample_app\n", encoding="utf-8")
    (repo / ".dart_tool" / "package_config.json").write_text("{}", encoding="utf-8")
    monkeypatch.delenv("VERAXI_SCIP_DART_BIN", raising=False)
    monkeypatch.setenv("VERAXI_SCIP_BIN", "/tools/scip")
    monkeypatch.setattr(cli_mod.shutil, "which", lambda _name: None)
    monkeypatch.setattr(cli_mod.Path, "home", lambda: tmp_path / "empty_home")

    with pytest.raises(SystemExit) as exc:
        run_xray_index_generate_scip(str(repo), lang="dart")
    assert exc.value.code == 1
    assert "scip_dart" in capsys.readouterr().err
