import json
import os
import sys
import urllib.error
import urllib.request
from veraxi.cli.client_configs import CLIENT_PATH_RESOLVERS


def check_endpoint(endpoint: str, key: str | None = None) -> tuple[bool, str]:
    """
    Pings the endpoint and checks for 200 or 401.
    Returns (Success, Message).
    """
    req = urllib.request.Request(endpoint)
    if key:
        req.add_header("Authorization", f"Bearer {key}")

    try:
        urllib.request.urlopen(req, timeout=5)
        return True, "200 OK - Authenticated"
    except urllib.error.HTTPError as e:
        if e.code == 401:
            if key:
                return False, "401 Unauthorized - Invalid Key"
            else:
                return True, "401 Unauthorized - Endpoint reachable (No key provided)"
        elif e.code == 405:
            return True, f"{e.code} - Endpoint reachable"
        return False, f"{e.code} {e.reason}"
    except Exception as e:
        return False, f"Connection Failed: {e}"


def run_doctor(endpoint: str, key: str | None = None):
    print("Veraxi MCP Doctor")
    print("=================\n")

    print("1. Testing Connectivity...")
    success, msg = check_endpoint(endpoint, key)
    if success:
        print(f"  [PASS] Endpoint: {endpoint} ({msg})")
    else:
        print(f"  [FAIL] Endpoint: {endpoint} ({msg})")

    print("\n2. Inspecting Client Configurations...")

    print(f"{'CLIENT':<15} | {'STATUS':<15} | {'DETAILS'}")
    print("-" * 60)

    for client_name, resolver in CLIENT_PATH_RESOLVERS.items():
        path = resolver()
        if not path.exists():
            print(f"{client_name:<15} | {'[NOT FOUND]':<15} | {path}")
            continue

        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)

            mcp_servers = data.get("mcpServers", {})
            if "veraxi" in mcp_servers:
                server_url = mcp_servers["veraxi"].get("url", "unknown")
                print(f"{client_name:<15} | {'[CONFIGURED]':<15} | {server_url}")
            else:
                print(f"{client_name:<15} | {'[MISSING]':<15} | 'veraxi' not in mcpServers")
        except Exception as e:
            print(f"{client_name:<15} | {'[ERROR]':<15} | Malformed JSON ({e})")

    print("\nDiagnostics complete.")
