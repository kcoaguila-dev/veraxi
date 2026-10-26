import argparse
import os
import sys
from veraxi.cli.chat import run_interactive_chat
from veraxi.cli.client_configs import CLIENT_PATH_RESOLVERS, update_mcp_config
from veraxi.cli.doctor import check_endpoint, run_doctor
from veraxi.cli.query import run_query


def _resolve_tenant_id(tenant_arg: str | None, key_arg: str | None) -> str:
    if tenant_arg:
        return tenant_arg

    key = key_arg or os.environ.get("VERAXI_API_KEY")
    if key and key.startswith("vx-"):
        try:
            from backend.config import get_config
            from supabase import create_client
            from backend.security.api_keys import resolve_api_key

            cfg = get_config()
            if cfg.supabase_url and cfg.supabase_service_key:
                sb = create_client(cfg.supabase_url, cfg.supabase_service_key)
                resolved = resolve_api_key(key, sb)
                if resolved:
                    return resolved
        except Exception:
            pass

    try:
        from backend.config import get_config
        cfg = get_config()
        if cfg.admin_tenant_ids:
            return cfg.admin_tenant_ids[0]
    except Exception:
        pass

    return "default"


def main():
    parser = argparse.ArgumentParser(
        prog="veraxi",
        description="Veraxi CLI: Interactive Knowledge Assistant & MCP Setup",
    )
    subparsers = parser.add_subparsers(dest="subcommand", help="Available subcommands")

    # --- chat ---
    chat_parser = subparsers.add_parser(
        "chat",
        help="Start an interactive terminal knowledge assistant",
    )
    chat_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    chat_parser.add_argument("--tenant", help="Tenant ID (defaults to resolving from key or config)")
    chat_parser.add_argument("--limit", type=int, default=5, help="Number of evidence chunks to retrieve")
    chat_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL")

    # --- research ---
    research_parser = subparsers.add_parser(
        "research",
        help="Deep research brief on a topic with linked entity graph anchors",
    )
    research_parser.add_argument("topic", help="Research topic or question")
    research_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    research_parser.add_argument("--tenant", help="Tenant ID (defaults to resolving from key or config)")
    research_parser.add_argument("--limit", type=int, default=10, help="Number of evidence chunks to retrieve")
    research_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL")
    research_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- mcp ---
    mcp_parser = subparsers.add_parser("mcp", help="Manage MCP configurations and test queries")
    mcp_subparsers = mcp_parser.add_subparsers(dest="command", help="MCP actions")

    # `veraxi mcp install ...`
    install_parser = mcp_subparsers.add_parser("install", help="1-Click automatic MCP configuration")
    install_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    install_parser.add_argument(
        "--client",
        choices=["claude", "cursor", "claude-code", "cline", "all"],
        default="all",
        help="Which client to configure",
    )
    install_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL")
    install_parser.add_argument("-y", "--yes", action="store_true", help="Auto-approve prompts for headless scripts")

    # `veraxi mcp doctor ...`
    doctor_parser = mcp_subparsers.add_parser("doctor", help="Run connectivity and configuration diagnosis")
    doctor_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    doctor_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL")

    # `veraxi mcp query ...`
    query_parser = mcp_subparsers.add_parser("query", help="Command-line test runner for headless agents")
    query_parser.add_argument("query_text", help="The query string")
    query_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    query_parser.add_argument("--tenant", help="Tenant ID (defaults to resolving from key or config)")
    query_parser.add_argument("--limit", type=int, default=5, help="Number of chunks to retrieve")
    query_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL")
    query_parser.add_argument("--json", action="store_true", help="Output raw JSON for pipeline integration")

    args = parser.parse_args()

    if not args.subcommand:
        # Default to interactive chat if run directly in an interactive shell
        if sys.stdin.isatty():
            tenant_id = _resolve_tenant_id(None, None)
            run_interactive_chat(tenant_id=tenant_id)
        else:
            parser.print_help()
        sys.exit(0)

    if args.subcommand == "chat":
        tenant_id = _resolve_tenant_id(args.tenant, args.key)
        run_interactive_chat(
            tenant_id=tenant_id,
            limit=args.limit,
            endpoint=args.endpoint,
            key=args.key,
        )

    elif args.subcommand == "research":
        tenant_id = _resolve_tenant_id(args.tenant, args.key)
        key = args.key or os.environ.get("VERAXI_API_KEY")
        run_query(
            args.topic,
            as_json=args.json,
            tenant_id=tenant_id,
            limit=args.limit,
            endpoint=args.endpoint,
            key=key,
        )

    elif args.subcommand == "mcp":
        if not args.command:
            mcp_parser.print_help()
            sys.exit(0)

        if args.command == "install":
            key = args.key or os.environ.get("VERAXI_API_KEY")
            is_headless = not sys.stdin.isatty()

            if not key and not is_headless:
                key = input("Enter your Veraxi API Key: ").strip()

            if not key and is_headless:
                print(
                    "Error: Headless environment detected. Please provide --key or set VERAXI_API_KEY.",
                    file=sys.stderr,
                )
                sys.exit(1)

            if not key:
                print("Error: No API key provided.", file=sys.stderr)
                sys.exit(1)

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
            tenant_id = _resolve_tenant_id(args.tenant, args.key)
            key = args.key or os.environ.get("VERAXI_API_KEY")
            run_query(
                args.query_text,
                as_json=args.json,
                tenant_id=tenant_id,
                limit=args.limit,
                endpoint=args.endpoint,
                key=key,
            )


if __name__ == "__main__":
    main()
