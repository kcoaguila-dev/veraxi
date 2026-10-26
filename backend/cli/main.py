import argparse
import sys
import os

from backend.cli.client_configs import CLIENT_PATH_RESOLVERS, update_mcp_config
from backend.cli.doctor import run_doctor, check_endpoint
from backend.cli.query import run_query
from backend.cli.review import run_review
from backend.cli.ingest import run_ingest


def _resolve_tenant(tenant_arg: str | None, key_arg: str | None) -> str:
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
    parser = argparse.ArgumentParser(description="Veraxi Developer CLI")
    subparsers = parser.add_subparsers(dest="mcp_group", required=True)

    # --- chat ---
    chat_parser = subparsers.add_parser("chat", help="Start an interactive terminal knowledge assistant")
    chat_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    chat_parser.add_argument("--tenant", help="Tenant ID (defaults to resolving from key or config)")
    chat_parser.add_argument("--limit", type=int, default=5, help="Number of evidence chunks to retrieve")

    # --- brief ---
    brief_parser = subparsers.add_parser(
        "brief",
        aliases=["research"],
        help="Generate a structured briefing doc on a topic with linked entity graph anchors",
    )
    brief_parser.add_argument("topic", help="Briefing topic or question")
    brief_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    brief_parser.add_argument("--tenant", help="Tenant ID (defaults to resolving from key or config)")
    brief_parser.add_argument("--limit", type=int, default=10, help="Number of evidence chunks to retrieve")
    brief_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- review ---
    review_parser = subparsers.add_parser("review", help="1-Command Git Diff Auditor")
    review_parser.add_argument("--staged", action="store_true", help="Review staged changes")
    review_parser.add_argument("--commit", help="Review a specific commit hash")
    review_parser.add_argument("--limit", type=int, default=10, help="Number of evidence chunks to retrieve")
    review_parser.add_argument("--key", help="Veraxi API key (vx-...)")

    # --- ingest ---
    ingest_parser = subparsers.add_parser("ingest", help="CLI Document & URL Ingest")
    ingest_parser.add_argument("target", help="File, directory, or URL to ingest")
    ingest_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    ingest_parser.add_argument("--endpoint", default="http://localhost:8000", help="Veraxi API endpoint")

    # "mcp" command group
    mcp_parser = subparsers.add_parser("mcp", help="MCP related commands")
    mcp_subparsers = mcp_parser.add_subparsers(dest="command", required=False)

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

    if args.mcp_group == "chat":
        tenant_id = _resolve_tenant(args.tenant, args.key)
        from backend.cli.chat import run_interactive_chat
        run_interactive_chat(tenant_id=tenant_id, limit=args.limit)

    elif args.mcp_group in ("brief", "research"):
        tenant_id = _resolve_tenant(args.tenant, args.key)
        run_query(args.topic, as_json=args.json, tenant_id=tenant_id, limit=args.limit)

    elif args.mcp_group == "review":
        tenant_id = _resolve_tenant(None, args.key)
        key = args.key or os.environ.get("VERAXI_API_KEY")
        run_review(
            staged=args.staged,
            commit_hash=args.commit,
            limit=args.limit,
            tenant_id=tenant_id,
            key=key,
        )

    elif args.mcp_group == "ingest":
        key = args.key or os.environ.get("VERAXI_API_KEY")
        run_ingest(
            target=args.target,
            key=key,
            endpoint=args.endpoint,
        )

    elif args.mcp_group == "mcp":
        if not args.command:
            mcp_parser.print_help()
            sys.exit(0)

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
            tenant_id = _resolve_tenant(args.tenant, args.key)
            run_query(args.query_text, as_json=args.json, tenant_id=tenant_id, limit=args.limit)

if __name__ == "__main__":
    main()
