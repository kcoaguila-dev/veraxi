import json
from unittest.mock import MagicMock, patch

import pytest
from veraxi.cli.client_configs import update_mcp_config
from veraxi.cli.doctor import check_endpoint
from veraxi.cli.init_project import init_project
from veraxi.cli.main import main


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
@patch("veraxi.cli.auth.load_credentials", return_value={})
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
@patch("veraxi.cli.main.run_query")
def test_main_pipe_handling(mock_run_query, mock_read, mock_isatty):
    main()
    mock_run_query.assert_called_once()
    args, _kwargs = mock_run_query.call_args
    assert "mock pipe error context" in args[0]

# 4. test_review_diff: Test run_review diff handling
@patch("veraxi.cli.review.run_query")
@patch("subprocess.run")
def test_review_diff(mock_subprocess_run, mock_run_query):
    from veraxi.cli.review import run_review

    # Mock unstaged check returning empty, then HEAD~1 returning diff
    mock_unstaged = MagicMock()
    mock_unstaged.stdout = ""

    mock_head = MagicMock()
    mock_head.stdout = "diff --git a/test b/test"

    mock_subprocess_run.side_effect = [mock_unstaged, mock_head]

    run_review()

    # run_query should be called with the diff
    assert mock_run_query.called
    _args, kwargs = mock_run_query.call_args
    assert "diff --git a/test b/test" in kwargs["query"]

# 5. test_review_empty_diff: Test run_review exits 0 if no diff
@patch("subprocess.run")
def test_review_empty_diff(mock_subprocess_run):
    from veraxi.cli.review import run_review

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
    from veraxi.cli.ingest import run_ingest

    mock_response = MagicMock()
    mock_response.getcode.return_value = 200
    mock_urlopen.return_value.__enter__.return_value = mock_response

    run_ingest("https://example.com/doc", key="vx-test")

    mock_urlopen.assert_called_once()
    req = mock_urlopen.call_args[0][0]
    assert req.full_url.endswith("/api/admin/ingest/url")
    assert req.headers.get("Authorization") == "Bearer vx-test"

# 7. test_ingest_file_401: Test file ingestion with 401
@patch("urllib.request.urlopen")
def test_ingest_file_401(mock_urlopen, tmp_path):
    import urllib.error

    from veraxi.cli.ingest import run_ingest

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
    from veraxi.cli import auth

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
    from veraxi.cli.stats import run_stats

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
    from veraxi.cli.completion import run_completion

    run_completion("bash")
    captured = capsys.readouterr()
    assert "_veraxi_completions" in captured.out
    assert "complete -F _veraxi_completions veraxi" in captured.out


# 11. test_hook_lifecycle: Test install and uninstall of git pre-commit hook
def test_hook_lifecycle(tmp_path):
    from veraxi.cli import hook

    fake_git_dir = tmp_path / ".git"
    fake_git_dir.mkdir()

    with patch.object(hook, "_find_git_dir", return_value=str(fake_git_dir)):
        hook.run_hook("install", hook_type="all")
        pre_file = fake_git_dir / "hooks" / "pre-commit"
        post_file = fake_git_dir / "hooks" / "post-commit"
        assert pre_file.exists()
        assert post_file.exists()
        assert "veraxi review --staged" in pre_file.read_text()
        assert "veraxi learn --auto" in post_file.read_text()

        # Idempotent install
        hook.run_hook("install", hook_type="all")

        # Uninstall
        hook.run_hook("uninstall", hook_type="all")
        assert not pre_file.exists()
        assert not post_file.exists()


# 12. test_schema_json_output: Test schema command output
@patch("backend.mcp_server.tools.get_schema.get_graph_schema")
def test_schema_json_output(mock_get_schema, capsys):
    from veraxi.cli.schema import run_schema

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
    from veraxi.cli.trace import run_trace

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
    from veraxi.cli.check import run_check

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
    from veraxi.cli.memory import run_memory_list, run_remember, run_resolve

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
        from veraxi.cli.memory import run_reopen
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
    from veraxi.cli.context import run_context

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client
        mock_client.execute_read.side_effect = [
            [{"repos": ["veraxi"]}],  # get_cluster_repos
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


# 17. test_cluster_lifecycle: Test repository clustering commands
def test_cluster_lifecycle(capsys):
    from veraxi.cli.cluster import get_cluster_repos, run_cluster

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client

        # Add cluster
        mock_client.execute_read.return_value = []
        run_cluster("add", name="auth-stack", repos=["frontend", "auth-service"], as_json=True)
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert data["name"] == "auth-stack"
        assert "frontend" in data["repos"]

        # List cluster
        mock_client.execute_read.return_value = [
            {"name": "auth-stack", "repos": ["frontend", "auth-service"]}
        ]
        run_cluster("list", as_json=True)
        captured = capsys.readouterr()
        list_data = json.loads(captured.out)
        assert len(list_data) == 1
        assert list_data[0]["name"] == "auth-stack"

        # get_cluster_repos
        mock_client.execute_read.return_value = [
            {"repos": ["frontend", "auth-service"]}
        ]
        sisters = get_cluster_repos("frontend")
        assert "auth-service" in sisters
        assert "frontend" in sisters


# 18. test_impact_analysis: Test architectural blast radius analysis
def test_impact_analysis(capsys):
    from veraxi.cli.impact import run_impact

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client

        mock_client.execute_read.return_value = [
            {"name": "POST /api/v1/auth", "labels": ["Endpoint"], "rels": ["INVOKES"]},
            {"name": "test_auth.py", "labels": ["Test"], "rels": ["DEPENDS_ON"]},
            {"name": "AuthService", "labels": ["Service"], "rels": ["CALLS"]},
        ]

        run_impact("validate_token", hops=2, as_json=True)
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert data["target"] == "validate_token"
        assert data["total_dependents"] == 3
        assert data["risk_level"] == "MEDIUM"
        assert len(data["by_category"]["Endpoints & APIs"]) == 1
        assert len(data["by_category"]["Tests & Verification"]) == 1
        assert "test_auth.py" in data["required_tests"]


# 19. test_impact_offline_static_scan: Test local static fallback
def test_impact_offline_static_scan(capsys, tmp_path):
    from veraxi.cli.impact import run_impact

    # Create dummy repo files
    (tmp_path / "routes").mkdir()
    (tmp_path / "tests").mkdir()
    api_file = tmp_path / "routes" / "api.py"
    test_file = tmp_path / "tests" / "test_client.py"

    api_file.write_text("from storage import CustomClient\nCustomClient.do_work()\n")
    test_file.write_text("import CustomClient\n")

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config", side_effect=Exception("Offline")):
        run_impact("CustomClient", hops=2, root_dir=str(tmp_path), as_json=True)
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert data["target"] == "CustomClient"
        assert data["total_dependents"] == 2
        assert data["risk_level"] == "LOW"
        assert data["source"] == "static_ast"


# 20. test_rules_sync: Test atomic syncing of active rules into CLAUDE.md and .cursorrules
def test_rules_sync(tmp_path):
    from veraxi.cli.rules import run_rules_sync

    claude_md = tmp_path / "CLAUDE.md"
    claude_md.write_text("# Project Guidelines\nExisting manual instructions.\n")

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client
        mock_client.execute_read.side_effect = [
            [{"repos": ["veraxi"]}],  # get_cluster_repos
            [{"id": "rule-1", "name": "Always use RS256 for tokens", "tag": "auth", "project": "veraxi"}],
        ]

        with patch("os.getcwd", return_value=str(tmp_path)), patch("subprocess.check_output", return_value=str(tmp_path)):
            run_rules_sync(target="claude", project="veraxi", as_json=True)

    content = claude_md.read_text()
    assert "Existing manual instructions." in content
    assert "VERAXI_MANAGED_START" in content
    assert "Always use RS256 for tokens" in content
    assert "VERAXI_MANAGED_END" in content


# 21. test_memory_export_and_import: Test Git rulebook JSON export and import
def test_memory_export_and_import(tmp_path):
    from veraxi.cli.memory import run_memory_export, run_memory_import

    export_file = tmp_path / "rules.json"

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client
        mock_client.execute_read.return_value = [
            {"id": "mem-1", "name": "Rule one", "tag": "db", "status": "active", "project": "test-repo"}
        ]

        # Export
        run_memory_export(output_path=str(export_file), project="test-repo")
        assert export_file.is_file()

        with open(export_file) as f:
            data = json.load(f)
        assert data["total"] == 1
        assert data["memories"][0]["id"] == "mem-1"

        # Import
        run_memory_import(file_path=str(export_file), project="test-repo")
        assert mock_client.execute_write.called


# 22. test_memory_audit: Test memory bank health scoring
def test_memory_audit(capsys):
    from veraxi.cli.memory import run_memory_audit

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client
        mock_client.execute_read.return_value = [
            {"id": "m1", "name": "Rule 1", "tag": "db", "status": "active"},
            {"id": "m2", "name": "Rule 2", "tag": "db", "status": "active"},
            {"id": "m3", "name": "Rule 3", "tag": "db", "status": "active"},
            {"id": "m4", "name": "Old bug", "tag": "auth", "status": "resolved"},
        ]

        run_memory_audit(project="test-repo", as_json=True)
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert data["total"] == 4
        assert data["active_count"] == 3
        assert data["resolved_count"] == 1
        assert "db" in data["crowded_tags"]
        assert data["health_score"] < 100


# 23. test_memory_prune: Test pruning resolved memories with dry-run and archive
def test_memory_prune(capsys, tmp_path):
    from veraxi.cli.memory import run_memory_prune

    archive_file = tmp_path / "archive.json"

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client
        mock_client.execute_read.return_value = [
            {"id": "old-1", "name": "Old bug", "tag": "db", "status": "resolved", "created_at": "2024-01-01T00:00:00Z"}
        ]

        # Dry run
        run_memory_prune(older_than="30d", dry_run=True, project="test-repo", as_json=True)
        captured = capsys.readouterr()
        dry_data = json.loads(captured.out)
        assert dry_data["dry_run"] is True
        assert dry_data["pruned_count"] == 1
        assert not mock_client.execute_write.called

        # Actual execution
        run_memory_prune(older_than="30d", dry_run=False, archive_file=str(archive_file), project="test-repo", as_json=True)
        assert mock_client.execute_write.called
        assert archive_file.is_file()


# 24. test_memory_stats: Test prompt token overhead & quota capacity estimation
def test_memory_stats(capsys):
    from veraxi.cli.memory import run_memory_stats

    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client
        mock_client.execute_read.side_effect = [
            # memories
            [
                {"id": "r1", "name": "Active rule 1", "tag": "auth", "status": "active"},
                {"id": "r2", "name": "Active rule 2", "tag": "db", "status": "active"},
                {"id": "r3", "name": "Resolved issue", "tag": "api", "status": "resolved"},
            ],
            # count query
            [{"cnt": 150}],
        ]

        run_memory_stats(project="test-repo", as_json=True)
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert data["hot_memory"]["active_rules_count"] == 2
        assert data["hot_memory"]["estimated_prompt_tokens"] > 0
        assert data["database_capacity"]["stored_nodes"] == 150
        assert data["database_capacity"]["status"] == "OPTIMAL"
        assert data["lifecycle"]["resolved"] == 1


# 25. test_backend_cli_forwarding_compatibility: Verify legacy backend.cli forwarders map to veraxi.cli
def test_backend_cli_forwarding_compatibility():
    import veraxi.cli.auth as v_auth
    import veraxi.cli.main as v_main

    import backend.cli.auth as b_auth
    import backend.cli.main as b_main

    assert b_main is v_main
    assert b_auth is v_auth


# 26. test_rules_lint_conflict_detection: Verify semantic contradiction & conflict detection
def test_rules_lint_conflict_detection(capsys):
    from veraxi.cli.rules import detect_rule_conflicts, run_rules_lint

    conflicting_rules = [
        {"id": "r1", "name": "Always use httpOnly cookies for authentication sessions", "tag": "auth", "status": "active"},
        {"id": "r2", "name": "Never use cookies, pass Bearer tokens in Authorization headers", "tag": "auth", "status": "active"},
        {"id": "r3", "name": "All database queries must filter by tenant_id", "tag": "db", "status": "active"},
    ]

    conflicts = detect_rule_conflicts(conflicting_rules)
    assert len(conflicts) >= 1
    assert any(c["type"] in ("contradiction", "polarity_clash") for c in conflicts)

    # Test run_rules_lint execution with mocked active rules
    with patch("veraxi.cli.rules._get_active_rules", return_value=conflicting_rules):
        run_rules_lint(project="test-repo", as_json=True)
        captured = capsys.readouterr()
        res = json.loads(captured.out)
        assert res["clean"] is False
        assert res["conflicts_count"] >= 1

        # Test strict mode raises SystemExit(1)
        with pytest.raises(SystemExit) as exc_info:
            run_rules_lint(project="test-repo", strict=True)
        assert exc_info.value.code == 1

    # Test clean rules
    clean_rules = [
        {"id": "c1", "name": "All database queries must filter by tenant_id", "tag": "db", "status": "active"},
        {"id": "c2", "name": "Use snake_case for Python function identifiers", "tag": "style", "status": "active"},
    ]
    assert len(detect_rule_conflicts(clean_rules)) == 0


# 27. test_learn_lifecycle: Verify autonomous memory extraction from git commits
def test_learn_lifecycle(capsys):
    from veraxi.cli.learn import extract_commit_lesson, run_learn

    # Mock git log returning architectural fix
    mock_log = "abc1234\x00fix(auth): rotate refresh tokens during session refresh\x00Resolves token expiration drops."
    with patch("subprocess.check_output") as mock_sub:
        mock_sub.side_effect = [
            mock_log,
            "backend/auth.py\nbackend/session.py\n",
        ]
        lesson = extract_commit_lesson("HEAD")
        assert lesson is not None
        assert lesson["tag"] == "auth"
        assert "Rotate refresh tokens during session refresh" in lesson["rule"]

    # Mock trivial commit (chore) returning None
    with patch("subprocess.check_output", return_value="def5678\x00chore: bump version to 0.1.1\x00"):
        assert extract_commit_lesson("HEAD") is None

    # Test run_learn auto-persisting
    with patch("veraxi.cli.learn.extract_commit_lesson") as mock_extract:
        mock_extract.return_value = {
            "commit": "abc1234",
            "short_hash": "abc1234",
            "subject": "fix(db): add tenant_id filter to all queries",
            "body": "",
            "rule": "Add tenant_id filter to all queries.",
            "tag": "db",
            "files_count": 2,
        }
        with patch("veraxi.cli.learn.run_remember") as mock_remember:
            run_learn(auto=True, project="test-project", tenant_id="default")
            mock_remember.assert_called_once()
            call_kwargs = mock_remember.call_args[1]
            assert call_kwargs["name"] == "Add tenant_id filter to all queries."
            assert call_kwargs["tag"] == "db"
            assert call_kwargs["project"] == "test-project"


# 28. test_audit_diff_rules_and_ci_gate: Verify CI rule enforcement against git diffs
def test_audit_diff_rules_and_ci_gate(capsys, tmp_path):
    from veraxi.cli.review import run_review
    from veraxi.cli.rules import audit_diff_against_rules, run_rules_sync

    active_rules = [
        {"id": "inv1", "name": "Clean Architecture: Domain entities must never import storage or database modules", "tag": "architecture", "type": "invariant", "status": "active"},
        {"id": "inv2", "name": "All database queries must filter by tenant_id", "tag": "db", "type": "rule", "status": "active"},
    ]

    violating_diff = """--- a/backend/domain/model.py
+++ b/backend/domain/model.py
@@ -1,3 +1,5 @@
+from backend.storage import neo4j_client
+data = neo4j_client.execute_read("MATCH (n) RETURN n")
"""

    violations = audit_diff_against_rules(violating_diff, active_rules)
    assert len(violations) >= 1
    assert any(v["type"] == "clean_architecture_violation" for v in violations)
    assert any(v["type"] == "multitenancy_leak" for v in violations)

    # Test run_review --enforce-rules failure
    mock_run = MagicMock()
    mock_run.stdout = violating_diff
    with patch("subprocess.run", return_value=mock_run), patch("veraxi.cli.review._get_active_rules", return_value=active_rules):
        with pytest.raises(SystemExit) as exc_info:
            run_review(enforce_rules=True, project="test-repo")
        assert exc_info.value.code == 1

    # Test run_review --enforce-rules pass on clean diff
    clean_diff = """--- a/backend/domain/model.py
+++ b/backend/domain/model.py
@@ -1,3 +1,4 @@
+class DomainUser: pass
"""
    mock_run.stdout = clean_diff
    with patch("subprocess.run", return_value=mock_run), patch("veraxi.cli.review._get_active_rules", return_value=active_rules):
        with pytest.raises(SystemExit) as exc_info:
            run_review(enforce_rules=True, project="test-repo")
        assert exc_info.value.code == 0

    # Test run_rules_sync groups permanent invariants at the top
    claude_file = tmp_path / "CLAUDE.md"
    claude_file.write_text("# Project Notes\n")
    with patch("veraxi.cli.rules._get_active_rules", return_value=active_rules), patch("subprocess.check_output", return_value=str(tmp_path)):
        run_rules_sync(target="claude", project="test-repo")
        content = claude_file.read_text()
        assert "### 🏛 Permanent Architectural Invariants" in content
        assert "Clean Architecture" in content


# 29. test_memory_drift_detection: Verify codebase drift, orphaned targets, and dependency divergence
def test_memory_drift_detection(tmp_path, capsys):
    from veraxi.cli.memory import detect_memory_drift, run_memory_audit

    # Create dummy pyproject.toml with upgraded pydantic v2
    pyproj = tmp_path / "pyproject.toml"
    pyproj.write_text('[project]\ndependencies = ["pydantic>=2.8.0", "fastapi>=0.110.0"]\n')

    # Existing file
    valid_file = tmp_path / "src" / "valid.py"
    valid_file.parent.mkdir()
    valid_file.write_text("# valid code\n")

    nodes = [
        {"id": "d1", "name": "Workaround for pydantic v1 validator bug in models", "tag": "db", "status": "active"},
        {"id": "d2", "name": "Ensure helper logic in src/nonexistent_old_file.py is pure", "tag": "architecture", "status": "active"},
        {"id": "d3", "name": "Valid rule in src/valid.py", "tag": "core", "status": "active"},
        {"id": "d4", "name": "Temporary workaround for upstream bug", "tag": "workaround", "status": "active", "created_at": "2024-01-01T00:00:00Z"},
    ]

    drift = detect_memory_drift(nodes, root_dir=str(tmp_path))
    assert len(drift) >= 2
    types = [item["type"] for item in drift]
    assert "dependency_drift" in types
    assert "orphaned_target" in types

    # Test run_memory_audit with drift output
    with patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config") as mock_neo4j:
        mock_client = MagicMock()
        mock_neo4j.return_value = mock_client
        mock_client.execute_read.return_value = nodes

        with patch("os.getcwd", return_value=str(tmp_path)):
            with pytest.raises(SystemExit) as exc_info:
                run_memory_audit(project="test-repo", strict=True)
            assert exc_info.value.code == 1


# 33. test_cli_config_lifecycle: Test get, set, unset, and list in CLI config
def test_cli_config_lifecycle(tmp_path, monkeypatch, capsys):
    from veraxi.cli.config import run_config

    fake_cfg_path = tmp_path / "config.json"
    monkeypatch.setattr("veraxi.cli.config.get_cli_config_path", lambda: fake_cfg_path)
    monkeypatch.setattr("veraxi.cli.config.load_credentials", lambda: {"api_key": "vx-test-secret-key"})

    # 1. Set key
    run_config(action="set", key="default_model", value="gpt-4o")
    captured = capsys.readouterr()
    assert "default_model = gpt-4o" in captured.out

    # 2. Get key
    run_config(action="get", key="default_model", as_json=True)
    captured = capsys.readouterr()
    assert json.loads(captured.out)["default_model"] == "gpt-4o"

    # 3. List
    run_config(action="list", as_json=True)
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["default_model"] == "gpt-4o"
    assert data["api_key"] == "vx-test-secret-key"

    # 4. Unset key
    run_config(action="unset", key="default_model")
    captured = capsys.readouterr()
    assert "Removed config key: default_model" in captured.out


# 34. test_cli_models_discovery: Test listing models and setting active model
def test_cli_models_discovery(tmp_path, monkeypatch, capsys):
    from veraxi.cli.models import run_models_list, run_models_set

    fake_cfg_path = tmp_path / "config.json"
    monkeypatch.setattr("veraxi.cli.config.get_cli_config_path", lambda: fake_cfg_path)
    monkeypatch.setattr("veraxi.cli.config.load_credentials", dict)

    # Set default model
    run_models_set(model_name="claude-3-5-sonnet-latest")
    captured = capsys.readouterr()
    assert "claude-3-5-sonnet-latest" in captured.out

    # List as JSON
    run_models_list(as_json=True)
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["current_model"] == "claude-3-5-sonnet-latest"
    assert "OpenAI" in data["providers"]
    assert "Anthropic" in data["providers"]


# 35. test_doctor_termux_detection: Test Android/Termux environment detection
def test_doctor_termux_detection(monkeypatch, capsys):
    from veraxi.cli.doctor import run_doctor

    monkeypatch.setenv("TERMUX_VERSION", "0.118.0")
    monkeypatch.setattr("veraxi.cli.doctor.check_endpoint", lambda endpoint, key: (True, "200 OK"))
    monkeypatch.setattr("veraxi.cli.doctor.CLIENT_PATH_RESOLVERS", {})

    run_doctor(endpoint="https://api.veraxi.me/sse")
    captured = capsys.readouterr()
    assert "Android / Termux" in captured.out
    assert "Pure Python stdlib mode active" in captured.out


# 36. test_cli_completion_includes_config_and_models: Test bash/zsh completion includes new subcommands
def test_cli_completion_includes_config_and_models(capsys):
    from veraxi.cli.completion import run_completion

    run_completion(shell="bash")
    captured = capsys.readouterr()
    assert "config" in captured.out
    assert "models" in captured.out

    run_completion(shell="zsh")
    captured = capsys.readouterr()
    assert "config:" in captured.out
    assert "models:" in captured.out


# 37. test_copy_to_clipboard: Test cross-platform clipboard copy helper
def test_copy_to_clipboard(monkeypatch):
    from veraxi.cli.utils import copy_to_clipboard

    assert copy_to_clipboard("") is False

    # Simulate success in subprocess
    mock_proc = MagicMock()
    mock_proc.communicate.return_value = (b"", b"")
    mock_proc.returncode = 0
    monkeypatch.setattr("subprocess.Popen", lambda *args, **kwargs: mock_proc)
    monkeypatch.setenv("TERMUX_VERSION", "0.118.0")

    result = copy_to_clipboard("test clip")
    assert result is True


# 38. test_cli_web_search_and_fetch: Test web search and page fetch handlers
def test_cli_web_search_and_fetch(monkeypatch, capsys):
    from veraxi.cli.web import run_web

    fake_results = [{"snippet": "Run AI on mobile", "url": "https://example.com"}]
    monkeypatch.setattr("veraxi.cli.web.web_search", lambda query, limit=5, provider=None: fake_results)
    monkeypatch.setattr("veraxi.cli.web.fetch_web_page", lambda url, max_chars=5000: "Clean Markdown Content")

    # 1. Search text
    run_web(action="search", query_or_url="termux agent")
    captured = capsys.readouterr()
    assert "Web Search Results" in captured.out
    assert "Run AI on mobile" in captured.out

    # 2. Search JSON
    run_web(action="search", query_or_url="termux agent", as_json=True)
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["query"] == "termux agent"
    assert data["results"][0]["snippet"] == "Run AI on mobile"

    # 3. Fetch text
    run_web(action="fetch", query_or_url="https://example.com")
    captured = capsys.readouterr()
    assert "Clean Markdown Content" in captured.out

    # 4. Fetch JSON
    run_web(action="fetch", query_or_url="https://example.com", as_json=True)
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["content"] == "Clean Markdown Content"


# 39. test_cli_chat_slash_commands: Test interactive chat REPL slash shortcuts
def test_cli_chat_slash_commands(monkeypatch, capsys):
    from veraxi.cli.chat import run_interactive_chat

    inputs = iter(["/help", "/web termux-test", "/models", "exit"])
    monkeypatch.setattr("builtins.input", lambda prompt="": next(inputs))
    monkeypatch.setattr("veraxi.cli.chat.run_web", lambda action, query_or_url, limit=5: print("MOCK_WEB_CALLED"))
    monkeypatch.setattr("veraxi.cli.chat.run_models_list", lambda *args, **kwargs: print("MOCK_MODELS_CALLED"))

    run_interactive_chat(tenant_id="test-tenant")
    captured = capsys.readouterr()
    assert "Available Commands & Shortcuts" in captured.out
    assert "MOCK_WEB_CALLED" in captured.out
    assert "MOCK_MODELS_CALLED" in captured.out
    assert "Session ended" in captured.out


# 40. test_cli_web_provider_management: Test listing and setting web search providers
def test_cli_web_provider_management(tmp_path, monkeypatch, capsys):
    from veraxi.cli.web import run_web

    fake_cfg_path = tmp_path / "config.json"
    monkeypatch.setattr("veraxi.cli.config.get_cli_config_path", lambda: fake_cfg_path)

    # 1. List providers as JSON
    run_web(action="provider", as_json=True)
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["active_provider"] == "duckduckgo"
    assert "searxng" in data["providers"]
    assert "serper" in data["providers"]
    assert "tavily" in data["providers"]

    # 2. Set provider to searxng
    run_web(action="provider", query_or_url="set", provider_name="searxng")
    captured = capsys.readouterr()
    assert "searxng" in captured.out

    # 3. Verify updated active provider
    run_web(action="provider", as_json=True)
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["active_provider"] == "searxng"

















