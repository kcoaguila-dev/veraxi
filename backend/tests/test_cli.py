import json
from unittest.mock import patch, MagicMock

import pytest

import os
import sys

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
