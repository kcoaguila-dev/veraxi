"""Veraxi CLI Configuration Management.

Provides full parity with UI settings for headless environments:
manage API keys, default models, retrieval parameters, and endpoints.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

from veraxi.cli.auth import load_credentials


def get_cli_config_path() -> Path:
    """Returns path to ~/.veraxi/config.json."""
    return Path.home() / ".veraxi" / "config.json"


def load_cli_config() -> dict[str, Any]:
    """Loads combined configuration from ~/.veraxi/config.json and credentials.json."""
    config: dict[str, Any] = {}

    # 1. Base credentials
    creds = load_credentials()
    if creds:
        config.update(creds)

    # 2. Config file overrides
    cfg_path = get_cli_config_path()
    if cfg_path.exists():
        try:
            with open(cfg_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    config.update(data)
        except Exception:
            pass

    return config


def save_cli_config(data: dict[str, Any]) -> bool:
    """Saves dictionary to ~/.veraxi/config.json with safe file permissions."""
    cfg_path = get_cli_config_path()
    cfg_dir = cfg_path.parent
    try:
        cfg_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)

        try:
            cfg_path.chmod(0o600)
        except OSError:
            pass
        return True
    except Exception as e:
        print(f"Error saving config to {cfg_path}: {e}", file=sys.stderr)
        return False


def set_config_value(key: str, value: str) -> bool:
    """Sets a specific config key."""
    cfg = load_cli_config()
    # Normalize types if boolean or integer
    val: Any = value
    if value.lower() in ("true", "1", "yes"):
        val = True
    elif value.lower() in ("false", "0", "no"):
        val = False
    elif value.isdigit():
        val = int(value)

    cfg[key] = val
    return save_cli_config(cfg)


def unset_config_value(key: str) -> bool:
    """Removes a key from ~/.veraxi/config.json."""
    cfg_path = get_cli_config_path()
    if not cfg_path.exists():
        return False

    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if key in data:
            del data[key]
            save_cli_config(data)
            return True
    except Exception:
        pass
    return False


def _is_secret_key(k: str) -> bool:
    """Returns True when a config key names a secret value."""
    return any(
        term in k.lower()
        for term in ("key", "secret", "password", "token", "credential")
    )


def _redact_url_credentials(val: Any) -> Any:
    """Redacts userinfo credentials embedded in URL strings (e.g. REDIS_URL)."""
    if not isinstance(val, str) or "://" not in val:
        return val
    try:
        from urllib.parse import urlsplit, urlunsplit

        parsed = urlsplit(val)
        if parsed.username is None and parsed.password is None:
            return val
        host = parsed.hostname or ""
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        port = f":{parsed.port}" if parsed.port is not None else ""
        netloc = f"[REDACTED]@{host}{port}"
        return urlunsplit(
            (parsed.scheme, netloc, parsed.path, parsed.query, parsed.fragment)
        )
    except ValueError:
        return val


def _sanitize_config_value(key: str, val: Any) -> Any:
    """Redacts secret-named config values and credentials embedded in URLs."""
    if _is_secret_key(key):
        return "[REDACTED]"
    return _redact_url_credentials(val)


def mask_secret(val: Any) -> str:
    """Masks API keys and secrets for safe console display."""
    s = str(val)
    if len(s) <= 8:
        return "********"
    return f"{s[:4]}...{s[-4:]}"


def run_config(
    action: str = "list",
    key: str | None = None,
    value: str | None = None,
    as_json: bool = False,
) -> None:
    """Executes vx config subcommands: list, get, set, unset."""
    action = (action or "list").lower()

    if action == "set":
        if not key or value is None:
            print("Error: 'set' requires both <KEY> and <VALUE>. Example: vx config set default_model gpt-4o", file=sys.stderr)
            sys.exit(1)
        ok = set_config_value(key, value)
        if ok:
            print(f"✓ Config updated: {key} = {_sanitize_config_value(key, value)}")
        else:
            sys.exit(1)
        return

    if action == "unset":
        if not key:
            print("Error: 'unset' requires <KEY>. Example: vx config unset default_model", file=sys.stderr)
            sys.exit(1)
        ok = unset_config_value(key)
        if ok:
            print(f"✓ Removed config key: {key}")
        else:
            print(f"Key '{key}' not found in configuration.")
        return

    if action == "get":
        if not key:
            print("Error: 'get' requires <KEY>. Example: vx config get default_model", file=sys.stderr)
            sys.exit(1)
        cfg = load_cli_config()
        val = cfg.get(key)
        if as_json:
            print(
                json.dumps(
                    {key: _sanitize_config_value(key, val) if val is not None else None}
                )
            )
        else:
            if val is not None:
                print(_sanitize_config_value(key, val))
            else:
                print("(not set)")
                sys.exit(1)
        return

    # Default: list all configurations
    cfg = load_cli_config()

    # Also detect active environment variables
    env_keys = [
        "LLM_MODEL_NAME", "DEFAULT_SEARCH_LIMIT", "DEFAULT_MAX_HOPS",
        "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GROQ_API_KEY",
        "NEO4J_URI", "QDRANT_URL", "REDIS_URL"
    ]
    env_detected = {}
    for ek in env_keys:
        if os.environ.get(ek):
            env_detected[ek.lower()] = os.environ[ek]

    combined = {**env_detected, **cfg}

    # Build a sanitized copy so secret values never reach any output,
    # including machine-consumed JSON.
    sanitized = {k: _sanitize_config_value(k, v) for k, v in combined.items()}

    if as_json:
        print(json.dumps(sanitized, indent=2))
        return

    cyan = "\033[36m"
    bold = "\033[1m"
    dim = "\033[2m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi Active Configuration & Settings             ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")
    print(f"{dim}Config File: {get_cli_config_path()}{reset}\n")

    if not combined:
        print(f"  {dim}No custom configurations set. Using defaults.{reset}")
        print("  Use 'vx config set <KEY> <VALUE>' to configure settings.\n")
        return

    print(f"  {'SETTING':<26} | {'VALUE':<30} | {'SOURCE'}")
    print("  " + "─" * 68)

    for k, v in sorted(sanitized.items()):
        display_val = str(v)
        source = "environment" if k in env_detected and k not in cfg else "config"
        print(f"  {k:<26} | {display_val:<30} | {dim}{source}{reset}")

    print("\n  Tip: Manage settings with: vx config set <key> <value>\n")
