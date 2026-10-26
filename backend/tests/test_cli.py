import json
from unittest.mock import patch, MagicMock

import pytest

from backend.cli.client_configs import update_mcp_config
from backend.cli.doctor import check_endpoint
from backend.cli.main import main

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
@patch("sys.stdin.isatty", return_value=False)
@patch("sys.argv", ["veraxi", "mcp", "install"])
@patch("os.environ.get", return_value=None) # No VERAXI_API_KEY
def test_mcp_install_headless_error(mock_env_get, mock_isatty):
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
