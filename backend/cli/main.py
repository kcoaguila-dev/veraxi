import argparse
import sys
import os

from backend.cli.client_configs import CLIENT_PATH_RESOLVERS, update_mcp_config
from backend.cli.doctor import run_doctor, check_endpoint
from backend.cli.query import run_query

def main():
    parser = argparse.ArgumentParser(description="Veraxi Developer CLI")
    subparsers = parser.add_subparsers(dest="mcp_group", required=True)

    # "mcp" command group
    mcp_parser = subparsers.add_parser("mcp", help="MCP related commands")
    mcp_subparsers = mcp_parser.add_subparsers(dest="command", required=True)

    # --- install ---
    install_parser = mcp_subparsers.add_parser("install", help="Configure local MCP clients")
    install_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    install_parser.add_argument("--client", choices=["claude", "cursor", "claude-code", "cline", "all"], default="all", help="Which client to configure")
    install_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL")
    install_parser.add_argument("-y", "--yes", action="store_true", help="Auto-approve prompts for headless scripts")

    # --- doctor ---
    doctor_parser = mcp_subparsers.add_parser("doctor", help="Run connectivity and configuration diagnosis")
    doctor_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    doctor_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL")

    # --- query ---
    query_parser = mcp_subparsers.add_parser("query", help="Command-line test runner for headless agents")
    query_parser.add_argument("query_text", help="The query string")
    query_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    query_parser.add_argument("--tenant", help="Tenant ID (defaults to resolving from key or config)")
    query_parser.add_argument("--limit", type=int, default=5, help="Number of chunks to retrieve")
    query_parser.add_argument("--json", action="store_true", help="Output raw JSON for pipeline integration")

    args = parser.parse_args()

    if args.command == "install":
        key = args.key or os.environ.get("VERAXI_API_KEY")

        is_headless = not sys.stdin.isatty()

        if not key and not is_headless:
            key = input("Enter your Veraxi API Key: ").strip()

        if not key and is_headless:
            print("Error: Headless environment detected. Please provide --key or set VERAXI_API_KEY.", file=sys.stderr)
            sys.exit(1)

        if not key:
            print("Error: No API key provided.", file=sys.stderr)
            sys.exit(1)

        # Pre-flight check
        print(f"Verifying key with endpoint {args.endpoint}...")
        success, msg = check_endpoint(args.endpoint, key)
        if not success:
            print(f"Error verifying key: {msg}", file=sys.stderr)
            sys.exit(1)

        clients_to_update = []
        if args.client == "all":
            clients_to_update = list(CLIENT_PATH_RESOLVERS.keys())
        else:
            clients_to_update = [args.client]

        for client in clients_to_update:
            resolver = CLIENT_PATH_RESOLVERS[client]
            path = resolver()
            if update_mcp_config(path, key, args.endpoint):
                print(f"Successfully configured {client} at {path}")
            else:
                print(f"Failed to configure {client} at {path}", file=sys.stderr)

    elif args.command == "doctor":
        key = args.key or os.environ.get("VERAXI_API_KEY")
        run_doctor(args.endpoint, key)

    elif args.command == "query":
        tenant_id = args.tenant
        if not tenant_id:
            key = args.key or os.environ.get("VERAXI_API_KEY")
            if key and key.startswith("vx-"):
                try:
                    from backend.config import get_config
                    from supabase import create_client
                    from backend.security.api_keys import resolve_api_key

                    cfg = get_config()
                    if cfg.supabase_url and cfg.supabase_service_key:
                        sb = create_client(cfg.supabase_url, cfg.supabase_service_key)
                        tenant_id = resolve_api_key(key, sb)
                except Exception as e:
                    pass

        if not tenant_id:
            try:
                from backend.config import get_config
                cfg = get_config()
                if cfg.admin_tenant_ids:
                    tenant_id = cfg.admin_tenant_ids[0]
            except Exception:
                pass

        if not tenant_id:
            tenant_id = "default"

        run_query(args.query_text, as_json=args.json, tenant_id=tenant_id, limit=args.limit)

if __name__ == "__main__":
    main()
