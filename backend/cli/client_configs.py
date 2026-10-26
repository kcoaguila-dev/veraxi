import json
import os
import sys
from pathlib import Path

def get_claude_desktop_config_path() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"
    elif sys.platform == "win32":
        return Path(os.environ.get("APPDATA", "")) / "Claude" / "claude_desktop_config.json"
    else:
        return Path.home() / ".config" / "Claude" / "claude_desktop_config.json"

def get_cursor_config_path() -> Path:
    if sys.platform == "win32":
        return Path(os.environ.get("USERPROFILE", "")) / ".cursor" / "mcp.json"
    else:
        return Path.home() / ".cursor" / "mcp.json"

def get_claude_code_config_path() -> Path:
    if sys.platform == "win32":
        return Path(os.environ.get("USERPROFILE", "")) / ".claude.json"
    else:
        return Path.home() / ".claude.json"

def get_cline_config_path() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Code" / "User" / "globalStorage" / "saoudrizwan.claude-dev" / "settings" / "cline_mcp_settings.json"
    elif sys.platform == "win32":
        return Path(os.environ.get("APPDATA", "")) / "Code" / "User" / "globalStorage" / "saoudrizwan.claude-dev" / "settings" / "cline_mcp_settings.json"
    else:
        return Path.home() / ".config" / "Code" / "User" / "globalStorage" / "saoudrizwan.claude-dev" / "settings" / "cline_mcp_settings.json"

CLIENT_PATH_RESOLVERS = {
    "claude": get_claude_desktop_config_path,
    "cursor": get_cursor_config_path,
    "claude-code": get_claude_code_config_path,
    "cline": get_cline_config_path,
}

def update_mcp_config(filepath: Path, key: str, endpoint: str) -> bool:
    """
    Safely mutates the JSON configuration file to add/update the veraxi MCP server.
    Returns True if successful.
    """
    try:
        config_data = {}
        if filepath.exists():
            try:
                with open(filepath, "r", encoding="utf-8") as f:
                    content = f.read()
                    if content.strip():
                        config_data = json.loads(content)
            except json.JSONDecodeError:
                # If file exists but is invalid JSON, we start fresh but might want to back it up in a real world scenario
                pass

        if "mcpServers" not in config_data:
            config_data["mcpServers"] = {}

        config_data["mcpServers"]["veraxi"] = {
            "url": endpoint,
            "headers": {
                "Authorization": f"Bearer {key}"
            }
        }

        # Ensure parent directories exist
        filepath.parent.mkdir(parents=True, exist_ok=True)

        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(config_data, f, indent=2)
            f.write("\n")

        return True
    except Exception as e:
        print(f"Error updating {filepath}: {e}", file=sys.stderr)
        return False
