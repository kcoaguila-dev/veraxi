import json
from unittest.mock import patch, MagicMock

import pytest


from backend.cli.client_configs import update_mcp_config
from backend.cli.doctor import check_endpoint
from backend.cli.main import main
from backend.cli.init_project import init_project

# 1. test_client_configs_safe_mutation: Mock an existing config containing "github-mcp";
# verify veraxi is added without deleting "github-mcp".
def test_client_configs_safe_mutation(tmp_path):
    config_file = tmp_path / "mcp.json"

    # Setup initial valid config with another server
    initial_data = {
        "mcpServers": {
            "github-mcp": {
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-github"]
            }
        }
    }

    with open(config_file, "w", encoding="utf-8") as f:
        json.dump(initial_data, f)

    # Run the mutation
    success = update_mcp_config(config_file, "vx-testkey123", "https://api.veraxi.me/sse")

    assert success is True

    # Read back and verify
    with open(config_file, "r", encoding="utf-8") as f:
        result_data = json.load(f)

    assert "mcpServers" in result_data
    assert "github-mcp" in result_data["mcpServers"] # Must not delete other servers
    assert "veraxi" in result_data["mcpServers"]

    veraxi_node = result_data["mcpServers"]["veraxi"]
    assert veraxi_node["url"] == "https://api.veraxi.me/sse"
    assert veraxi_node["headers"]["Authorization"] == "Bearer vx-testkey123"

# 2. test_mcp_install_headless_error: Verify exit code 1 when no key is provided in a non-interactive shell.
@patch("backend.cli.auth.load_credentials", return_value={})
@patch("sys.stdin.isatty", return_value=False)
@patch("sys.argv", ["veraxi", "mcp", "install"])
@patch("os.environ.get", return_value=None) # No VERAXI_API_KEY
def test_mcp_install_headless_error(mock_env_get, mock_isatty, mock_load_creds):
    # Running main should raise SystemExit(1)
    with pytest.raises(SystemExit) as exc_info:
        main()

    assert exc_info.value.code == 1

# 3. test_doctor_validation: Test mock endpoint checks for 200 vs 401.
@patch("urllib.request.urlopen")
def test_doctor_validation_200(mock_urlopen):
    # Mocking successful request
    mock_response = MagicMock()
    mock_urlopen.return_value = mock_response

    success, msg = check_endpoint("https://api.veraxi.me/sse", "vx-valid")
    assert success is True
    assert "200 OK" in msg

@patch("urllib.request.urlopen")
def test_doctor_validation_401(mock_urlopen):
    # Mocking a 401 Unauthorized Error
    import urllib.error
    mock_urlopen.side_effect = urllib.error.HTTPError(
        url="https://api.veraxi.me/sse",
        code=401,
        msg="Unauthorized",
        hdrs=None,
        fp=None
    )

    # With a key provided, 401 should mean invalid key (Fail)
    success, msg = check_endpoint("https://api.veraxi.me/sse", "vx-invalid")
    assert success is False
    assert "401 Unauthorized" in msg

    # Without a key provided, 401 should mean endpoint reachable (Success for connectivity)
    success, msg = check_endpoint("https://api.veraxi.me/sse", None)
    assert success is True
    assert "401 Unauthorized" in msg

def test_init_command_creates_files(tmp_path):
    with patch("os.getcwd", return_value=str(tmp_path)):
        init_project()

    claude_md = tmp_path / "CLAUDE.md"
    cursorrules = tmp_path / ".cursorrules"

    assert claude_md.exists()
    assert cursorrules.exists()

    assert "AI Agent Instructions for Veraxi Knowledge Graph" in claude_md.read_text()
    assert "Veraxi Knowledge Graph Rules" in cursorrules.read_text()

@patch("sys.stdin.isatty", return_value=False)
@patch("sys.stdin.read", return_value="mock pipe error context")
@patch("sys.argv", ["veraxi", "mcp", "query"])
@patch("backend.cli.main.run_query")
def test_main_pipe_handling(mock_run_query, mock_read, mock_isatty):
    main()
    mock_run_query.assert_called_once()
    args, kwargs = mock_run_query.call_args
    assert "mock pipe error context" in args[0]

# 4. test_review_diff: Test run_review diff handling
@patch("backend.cli.review.run_query")
@patch("subprocess.run")
def test_review_diff(mock_subprocess_run, mock_run_query):
    from backend.cli.review import run_review

    # Mock unstaged check returning empty, then HEAD~1 returning diff
    mock_unstaged = MagicMock()
    mock_unstaged.stdout = ""

    mock_head = MagicMock()
    mock_head.stdout = "diff --git a/test b/test"

    mock_subprocess_run.side_effect = [mock_unstaged, mock_head]

    run_review()

    # run_query should be called with the diff
    assert mock_run_query.called
    args, kwargs = mock_run_query.call_args
    assert "diff --git a/test b/test" in kwargs["query"]

# 5. test_review_empty_diff: Test run_review exits 0 if no diff
@patch("subprocess.run")
def test_review_empty_diff(mock_subprocess_run):
    from backend.cli.review import run_review

    mock_unstaged = MagicMock()
    mock_unstaged.stdout = ""

    mock_head = MagicMock()
    mock_head.stdout = ""

    mock_subprocess_run.side_effect = [mock_unstaged, mock_head]

    with pytest.raises(SystemExit) as exc_info:
        run_review()

    assert exc_info.value.code == 0

# 6. test_ingest_url_200: Test URL ingestion
@patch("urllib.request.urlopen")
def test_ingest_url_200(mock_urlopen):
    from backend.cli.ingest import run_ingest

    mock_response = MagicMock()
    mock_response.getcode.return_value = 200
    mock_urlopen.return_value.__enter__.return_value = mock_response

    run_ingest("https://example.com/doc", key="vx-test")

    mock_urlopen.assert_called_once()
    req = mock_urlopen.call_args[0][0]
    assert req.full_url == "http://localhost:8000/api/admin/ingest/url"
    assert req.headers.get("Authorization") == "Bearer vx-test"

# 7. test_ingest_file_401: Test file ingestion with 401
@patch("urllib.request.urlopen")
def test_ingest_file_401(mock_urlopen, tmp_path):
    from backend.cli.ingest import run_ingest
    import urllib.error

    test_file = tmp_path / "test.md"
    test_file.write_text("test content")

    mock_urlopen.side_effect = urllib.error.HTTPError(
        url="http://localhost:8000/api/admin/ingest/upload",
        code=401,
        msg="Unauthorized",
        hdrs=None,
        fp=None
    )

    # Should not raise exception, just print error
    run_ingest(str(test_file), key="vx-bad")

    mock_urlopen.assert_called_once()

# 8. test_auth_save_and_load: Test credentials lifecycle
def test_auth_save_and_load(tmp_path):
    from backend.cli import auth

    cred_file = tmp_path / ".veraxi" / "credentials.json"
    with patch.object(auth, "get_credentials_path", return_value=cred_file):
        assert auth.load_credentials() == {}
        assert auth.save_credentials("vx-sample-key", "https://api.test/sse")
        loaded = auth.load_credentials()
        assert loaded.get("api_key") == "vx-sample-key"
        assert loaded.get("endpoint") == "https://api.test/sse"

        key, endpoint = auth.resolve_credentials()
        assert key == "vx-sample-key"
        assert endpoint == "https://api.test/sse"

        assert auth.delete_credentials()
        assert auth.load_credentials() == {}

# 9. test_stats_json_output: Test stats formatted output
@patch("backend.mcp_server.tools.get_stats.get_database_stats")
def test_stats_json_output(mock_get_stats, capsys):
    from backend.cli.stats import run_stats

    mock_get_stats.return_value = {
        "qdrant_vectors": 1234,
        "neo4j_nodes": 5678,
        "neo4j_relationships": 90,
    }

    run_stats(tenant_id="test-tenant", as_json=True)
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["qdrant_vectors"] == 1234
    assert data["neo4j_nodes"] == 5678

# 10. test_completion_output: Test shell completion output
def test_completion_output(capsys):
    from backend.cli.completion import run_completion

    run_completion("bash")
    captured = capsys.readouterr()
    assert "_veraxi_completions" in captured.out
    assert "complete -F _veraxi_completions veraxi" in captured.out


# 11. test_hook_lifecycle: Test install and uninstall of git pre-commit hook
def test_hook_lifecycle(tmp_path):
    from backend.cli import hook

    fake_git_dir = tmp_path / ".git"
    fake_git_dir.mkdir()

    with patch.object(hook, "_find_git_dir", return_value=str(fake_git_dir)):
        hook.run_hook("install")
        hook_file = fake_git_dir / "hooks" / "pre-commit"
        assert hook_file.exists()
        content = hook_file.read_text()
        assert "veraxi review --staged" in content

        # Idempotent install
        hook.run_hook("install")

        # Uninstall
        hook.run_hook("uninstall")
        assert not hook_file.exists()


# 12. test_schema_json_output: Test schema command output
@patch("backend.mcp_server.tools.get_schema.get_graph_schema")
def test_schema_json_output(mock_get_schema, capsys):
    from backend.cli.schema import run_schema

    mock_get_schema.return_value = {
        "node_labels": ["Concept", "Service"],
        "relationship_types": ["DEPENDS_ON"],
    }

    run_schema(as_json=True)
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert "Concept" in data["node_labels"]
    assert "DEPENDS_ON" in data["relationship_types"]


# 13. test_trace_json_output: Test trace path traversal
def test_trace_json_output(capsys):
    from backend.cli.trace import run_trace

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client
        mock_client.execute_read.return_value = [
            {"nodes": ["ServiceA", "ServiceB"], "rels": ["DEPENDS_ON"]}
        ]

        run_trace(entity="ServiceA", hops=1, as_json=True)
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert len(data) == 1
        assert data[0]["nodes"] == ["ServiceA", "ServiceB"]


# 14. test_check_gate: Test check command grounding threshold
def test_check_gate():
    from backend.cli.check import run_check

    with patch("backend.evaluation.grounding.evaluate_groundedness", return_value=0.95):
        with pytest.raises(SystemExit) as exc_info:
            run_check(text="True fact", context="True fact", min_score=0.8, as_json=True)
        assert exc_info.value.code == 0

    with patch("backend.evaluation.grounding.evaluate_groundedness", return_value=0.40):
        with pytest.raises(SystemExit) as exc_info:
            run_check(text="Hallucinated fact", context="Other fact", min_score=0.8, as_json=True)
        assert exc_info.value.code == 1


# 15. test_remember_and_resolve_lifecycle: Test architectural memory tracking
def test_remember_and_resolve_lifecycle(capsys):
    from backend.cli.memory import run_remember, run_resolve, run_memory_list

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client

        # Remember
        run_remember("Test rule", tag="test", as_json=True)
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert data["insight"] == "Test rule"
        assert data["status"] == "active"

        # Resolve
        mock_client.execute_read.return_value = [{"id": data["id"], "name": "Test rule"}]
        run_resolve(data["id"], ref="PR#1", note="Fixed", as_json=True)
        captured = capsys.readouterr()
        res_data = json.loads(captured.out)
        assert res_data["ref"] == "PR#1"

        # Reopen (Human Override)
        from backend.cli.memory import run_reopen
        run_reopen(data["id"], note="Still broken in staging", as_json=True)
        captured = capsys.readouterr()
        reopen_data = json.loads(captured.out)
        assert reopen_data["note"] == "Still broken in staging"

        # List
        mock_client.execute_read.return_value = [
            {"id": data["id"], "name": "Test rule", "tag": "test", "status": "resolved"}
        ]
        run_memory_list(as_json=True)
        captured = capsys.readouterr()
        list_data = json.loads(captured.out)
        assert len(list_data) == 1
        assert list_data[0]["status"] == "resolved"


# 16. test_context_packing: Test token-efficient context assembly
def test_context_packing(capsys):
    from backend.cli.context import run_context

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client
        mock_client.execute_read.side_effect = [
            [{"id": "mem-1", "name": "Active rule", "tag": "auth"}],  # active rules
            [{"id": "mem-2", "name": "Old caveat", "tag": "db", "ref": "PR#2", "note": "Solved"}],  # resolved caveats
        ]

        with patch("backend.mcp_server.tools.search_vectors.search_vectors", return_value=[]):
            run_context("Auth refactor task")
            captured = capsys.readouterr()
            assert "<veraxi-context" in captured.out
            assert "<active-rules>" in captured.out
            assert "Active rule" in captured.out
            assert "DO-NOT-RE-SOLVE" in captured.out
            assert "Old caveat" in captured.out



