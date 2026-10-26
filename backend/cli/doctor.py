import json
import urllib.request
import urllib.error
from backend.cli.client_configs import CLIENT_PATH_RESOLVERS

def check_endpoint(endpoint: str, key: str = None) -> tuple[bool, str]:
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
        elif e.code == 405: # SSE endpoints sometimes reject GET/POST without correct setup, but reachable
            return True, f"{e.code} - Endpoint reachable"
        return False, f"{e.code} {e.reason}"
    except Exception as e:
        return False, f"Connection Failed: {e}"

def run_doctor(endpoint: str, key: str = None):
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
                content = f.read()
                if not content.strip():
                    print(f"{client_name:<15} | {'[EMPTY]':<15} | {path}")
                    continue
                data = json.loads(content)

            servers = data.get("mcpServers", {})
            if "veraxi" not in servers:
                print(f"{client_name:<15} | {'[MISSING]':<15} | 'veraxi' not in mcpServers")
            else:
                veraxi_config = servers["veraxi"]
                configured_url = veraxi_config.get("url")
                if configured_url == endpoint:
                    print(f"{client_name:<15} | {'[PASS]':<15} | URL: {configured_url}")
                else:
                    print(f"{client_name:<15} | {'[WARN]':<15} | URL mismatch: {configured_url} != {endpoint}")
        except Exception as e:
            print(f"{client_name:<15} | {'[ERROR]':<15} | {e}")

    print("\nDiagnostics complete.")
