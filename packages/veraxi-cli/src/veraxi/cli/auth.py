import json
import os
import sys
from pathlib import Path

from veraxi.cli.doctor import check_endpoint


def get_credentials_path() -> Path:
    return Path.home() / ".veraxi" / "credentials.json"


def load_credentials() -> dict:
    cred_path = get_credentials_path()
    if cred_path.exists():
        try:
            with open(cred_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return data
        except Exception:
            return {}
    return {}


def save_credentials(key: str, endpoint: str = "https://api.veraxi.me/sse") -> bool:
    cred_path = get_credentials_path()
    cred_dir = cred_path.parent
    try:
        cred_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        with open(cred_path, "w", encoding="utf-8") as f:
            json.dump({"api_key": key, "endpoint": endpoint}, f, indent=2)

        try:
            cred_path.chmod(0o600)
        except OSError:
            pass
        return True
    except Exception as e:
        print(f"Error saving credentials to {cred_path}: {e}", file=sys.stderr)
        return False


def delete_credentials() -> bool:
    cred_path = get_credentials_path()
    if cred_path.exists():
        try:
            cred_path.unlink()
            return True
        except Exception as e:
            print(f"Error removing {cred_path}: {e}", file=sys.stderr)
            return False
    return False


def resolve_credentials(
    key_arg: str | None = None,
    endpoint_arg: str | None = None,
) -> tuple[str | None, str]:
    """
    Resolves API Key and Endpoint in priority order:
    1. Explicit CLI argument
    2. Environment variable (VERAXI_API_KEY / VERAXI_ENDPOINT)
    3. Stored credentials in ~/.veraxi/credentials.json
    4. Default values
    """
    creds = load_credentials()

    # 1. Resolve key
    key = key_arg or os.environ.get("VERAXI_API_KEY") or creds.get("api_key")

    # 2. Resolve endpoint
    default_endpoint = "https://api.veraxi.me/sse"
    endpoint = (
        endpoint_arg
        or os.environ.get("VERAXI_ENDPOINT")
        or creds.get("endpoint")
        or default_endpoint
    )

    return key, endpoint


def run_login(key: str | None = None, endpoint: str = "https://api.veraxi.me/sse"):
    if not key:
        is_headless = not sys.stdin.isatty()
        if is_headless:
            print(
                "Error: Headless environment. Provide key via --key or VERAXI_API_KEY.",
                file=sys.stderr,
            )
            sys.exit(1)
        key = input("Enter your Veraxi API Key (vx-...): ").strip()

    if not key:
        print("Error: No API key provided.", file=sys.stderr)
        sys.exit(1)

    print(f"Verifying API key with {endpoint}...")
    success, msg = check_endpoint(endpoint, key)
    if not success:
        print(f"Authentication failed: {msg}", file=sys.stderr)
        sys.exit(1)

    if save_credentials(key, endpoint):
        print(f"Successfully logged in. Credentials saved to {get_credentials_path()}.")
    else:
        sys.exit(1)


def run_whoami(key: str | None = None, endpoint: str = "https://api.veraxi.me/sse"):
    resolved_key, resolved_endpoint = resolve_credentials(key, endpoint)

    if not resolved_key:
        print("Not logged in. Run 'veraxi login' or set VERAXI_API_KEY.")
        sys.exit(0)

    # Mask key for safety
    masked_key = (
        resolved_key[:7] + "..." + resolved_key[-4:]
        if len(resolved_key) > 12
        else "****"
    )

    print("\nVeraxi Identity")
    print("===============")
    print(f"Endpoint    : {resolved_endpoint}")
    print(f"API Key     : {masked_key}")
    print(f"Credentials : {get_credentials_path()}")

    # Ping endpoint to check status
    success, msg = check_endpoint(resolved_endpoint, resolved_key)
    if success:
        print(f"Status      : Authenticated ({msg})\n")
    else:
        print(f"Status      : Warning ({msg})\n")


def run_logout():
    if delete_credentials():
        print("Successfully logged out. Credentials removed.")
    else:
        print("No stored credentials found.")
