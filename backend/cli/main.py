import argparse
import sys

from backend.cli.auth import resolve_credentials, run_login, run_logout, run_whoami
from backend.cli.check import run_check
from backend.cli.client_configs import CLIENT_PATH_RESOLVERS, update_mcp_config
from backend.cli.completion import run_completion
from backend.cli.context import run_context
from backend.cli.doctor import check_endpoint, run_doctor
from backend.cli.hook import run_hook
from backend.cli.ingest import run_ingest
from backend.cli.memory import run_memory_list, run_remember, run_reopen, run_resolve
from backend.cli.query import run_query
from backend.cli.review import run_review
from backend.cli.schema import run_schema
from backend.cli.stats import run_stats
from backend.cli.trace import run_trace


def _resolve_tenant(tenant_arg: str | None, key_arg: str | None) -> str:
    if tenant_arg:
        return tenant_arg

    key, _ = resolve_credentials(key_arg)
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

    # --- init ---
    init_parser = subparsers.add_parser(
        "init",
        help="Initialize Veraxi knowledge graph instructions",
    )
    init_parser.add_argument("--force", action="store_true", help="Overwrite existing instructions")

    # --- brief ---
    brief_parser = subparsers.add_parser(
        "brief",
        aliases=["research"],
        help="Generate a structured briefing doc on a topic with linked entity graph anchors",
    )
    brief_parser.add_argument("topic", nargs="?", help="Briefing topic or question")
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

    # --- login ---
    login_parser = subparsers.add_parser("login", help="Authenticate and save API key locally")
    login_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    login_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL")

    # --- whoami ---
    whoami_parser = subparsers.add_parser("whoami", help="Display current active identity & credentials")
    whoami_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    whoami_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL")

    # --- logout ---
    subparsers.add_parser("logout", help="Log out and remove stored credentials")

    # --- stats ---
    stats_parser = subparsers.add_parser("stats", help="Display database & knowledge graph health dashboard")
    stats_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    stats_parser.add_argument("--tenant", help="Tenant ID (defaults to resolving from key or config)")
    stats_parser.add_argument("--endpoint", default="http://localhost:8000", help="Veraxi API endpoint")
    stats_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- completion ---
    completion_parser = subparsers.add_parser("completion", help="Generate shell auto-completion script")
    completion_parser.add_argument("shell", choices=["bash", "zsh"], default="bash", nargs="?", help="Shell type")

    # --- hook ---
    hook_parser = subparsers.add_parser("hook", help="Manage Git pre-commit hooks for architectural review")
    hook_parser.add_argument("action", choices=["install", "uninstall"], default="install", nargs="?", help="Action to perform (default: install)")

    # --- schema ---
    schema_parser = subparsers.add_parser("schema", help="Display knowledge graph ontology and schema")
    schema_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    schema_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    schema_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- trace ---
    trace_parser = subparsers.add_parser("trace", help="Trace multi-hop causal/dependency paths for an entity")
    trace_parser.add_argument("entity", help="Entity or symbol name to trace")
    trace_parser.add_argument("--hops", type=int, default=2, help="Max traversal depth (default: 2)")
    trace_parser.add_argument("--tenant", help="Tenant ID")
    trace_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    trace_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    trace_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- check ---
    check_parser = subparsers.add_parser("check", help="Grounding and factual accuracy gatekeeper for CI")
    check_parser.add_argument("text", nargs="?", help="Claim or text to verify against knowledge base")
    check_parser.add_argument("--context", help="Explicit context string or file path")
    check_parser.add_argument("--min-score", type=float, default=0.8, help="Minimum passing grounding threshold (default: 0.8)")
    check_parser.add_argument("--tenant", help="Tenant ID")
    check_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    check_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    check_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- context ---
    context_parser = subparsers.add_parser("context", help="Assemble token-efficient grounding context for agents")
    context_parser.add_argument("task", nargs="?", help="Task or prompt description")
    context_parser.add_argument("--project", help="Project repository scope (defaults to auto-detected git repo)")
    context_parser.add_argument("--tenant", help="Tenant ID")
    context_parser.add_argument("--limit", type=int, default=4, help="Max vector chunks to include")
    context_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    context_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    context_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- remember ---
    remember_parser = subparsers.add_parser("remember", help="Save an architectural rule or constraint to memory")
    remember_parser.add_argument("insight", help="The architectural rule, pattern, or constraint")
    remember_parser.add_argument("--tag", help="Category tag (e.g., auth, perf, db)")
    remember_parser.add_argument("--type", choices=["rule", "issue", "pattern"], default="rule", help="Type of memory")
    remember_parser.add_argument("--supersedes", help="ID or keyword of older memory this replaces")
    remember_parser.add_argument("--project", help="Project repository scope (defaults to auto-detected git repo)")
    remember_parser.add_argument("--global", dest="is_global", action="store_true", help="Apply across all projects")
    remember_parser.add_argument("--tenant", help="Tenant ID")
    remember_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    remember_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    remember_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- resolve ---
    resolve_parser = subparsers.add_parser("resolve", help="Mark an issue or caveat as resolved (prevents re-solving)")
    resolve_parser.add_argument("target", help="Memory ID or keyword to resolve")
    resolve_parser.add_argument("--ref", help="Commit hash, PR number, or ticket")
    resolve_parser.add_argument("--note", help="Explanation of resolution")
    resolve_parser.add_argument("--tenant", help="Tenant ID")
    resolve_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    resolve_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    resolve_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- reopen ---
    reopen_parser = subparsers.add_parser("reopen", help="Human override: reopen a prematurely resolved memory")
    reopen_parser.add_argument("target", help="Memory ID or keyword to reopen")
    reopen_parser.add_argument("--note", help="Reason for reopening (e.g. still failing)")
    reopen_parser.add_argument("--tenant", help="Tenant ID")
    reopen_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    reopen_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    reopen_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- memory ---
    memory_parser = subparsers.add_parser("memory", help="Inspect and list architectural memories")
    memory_parser.add_argument("--status", choices=["active", "resolved", "superseded", "all"], default="all", help="Status filter")
    memory_parser.add_argument("--project", help="Project repository filter (defaults to current git repo)")
    memory_parser.add_argument("--all-projects", action="store_true", help="Display memories across all projects")
    memory_parser.add_argument("--tenant", help="Tenant ID")
    memory_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    memory_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    memory_parser.add_argument("--json", action="store_true", help="Output raw JSON")

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
    query_parser.add_argument("query_text", nargs="?", help="The query string")
    query_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    query_parser.add_argument("--tenant", help="Tenant ID (defaults to resolving from key or config)")
    query_parser.add_argument("--limit", type=int, default=5, help="Number of chunks to retrieve")
    query_parser.add_argument("--json", action="store_true", help="Output raw JSON for pipeline integration")

    args = parser.parse_args()

    if args.mcp_group == "login":
        run_login(key=args.key, endpoint=args.endpoint)

    elif args.mcp_group == "whoami":
        run_whoami(key=args.key, endpoint=args.endpoint)

    elif args.mcp_group == "logout":
        run_logout()

    elif args.mcp_group == "stats":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant(args.tenant, key)
        run_stats(tenant_id=tenant_id, endpoint=endpoint, key=key, as_json=args.json)

    elif args.mcp_group == "completion":
        run_completion(shell=args.shell)

    elif args.mcp_group == "hook":
        run_hook(action=args.action)

    elif args.mcp_group == "schema":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        run_schema(endpoint=endpoint, key=key, as_json=args.json)

    elif args.mcp_group == "trace":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant(args.tenant, key)
        run_trace(
            entity=args.entity,
            hops=args.hops,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.mcp_group == "check":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant(args.tenant, key)
        run_check(
            text=args.text,
            context=args.context,
            min_score=args.min_score,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.mcp_group == "context":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant(args.tenant, key)
        run_context(
            task=args.task,
            project=args.project,
            tenant_id=tenant_id,
            limit=args.limit,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.mcp_group == "remember":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant(args.tenant, key)
        run_remember(
            insight=args.insight,
            tag=args.tag,
            memory_type=args.type,
            supersedes=args.supersedes,
            project=args.project,
            is_global=args.is_global,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.mcp_group == "resolve":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant(args.tenant, key)
        run_resolve(
            target=args.target,
            ref=args.ref,
            note=args.note,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.mcp_group == "reopen":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant(args.tenant, key)
        run_reopen(
            target=args.target,
            note=args.note,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.mcp_group == "memory":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant(args.tenant, key)
        run_memory_list(
            status_filter=args.status,
            project=args.project,
            all_projects=args.all_projects,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.mcp_group == "chat":
        key, _ = resolve_credentials(args.key)
        tenant_id = _resolve_tenant(args.tenant, key)
        from backend.cli.chat import run_interactive_chat
        run_interactive_chat(tenant_id=tenant_id, limit=args.limit)

    elif args.mcp_group == "init":
        from backend.cli.init_project import init_project
        init_project(force=args.force)

    elif args.mcp_group in ("brief", "research"):
        piped_input = ""
        if not sys.stdin.isatty():
            piped_input = sys.stdin.read().strip()

        topic = args.topic
        if piped_input:
            if topic:
                topic = f"{topic}\n\n[Piped Context]:\n{piped_input}"
            else:
                topic = piped_input
        else:
            if not topic:
                print("Error: topic is required if no input is piped.", file=sys.stderr)
                sys.exit(1)

        key, _ = resolve_credentials(args.key)
        tenant_id = _resolve_tenant(args.tenant, key)
        run_query(topic, as_json=args.json, tenant_id=tenant_id, limit=args.limit)

    elif args.mcp_group == "review":
        key, _ = resolve_credentials(args.key)
        tenant_id = _resolve_tenant(None, key)
        run_review(
            staged=args.staged,
            commit_hash=args.commit,
            limit=args.limit,
            tenant_id=tenant_id,
            key=key,
        )

    elif args.mcp_group == "ingest":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        run_ingest(
            target=args.target,
            key=key,
            endpoint=endpoint,
        )

    elif args.mcp_group == "mcp":
        if not args.command:
            mcp_parser.print_help()
            sys.exit(0)

        if args.command == "install":
            key, endpoint = resolve_credentials(args.key, args.endpoint)

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
            print(f"Verifying key with endpoint {endpoint}...")
            success, msg = check_endpoint(endpoint, key)
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
                if update_mcp_config(path, key, endpoint):
                    print(f"Successfully configured {client} at {path}")
                else:
                    print(f"Failed to configure {client} at {path}", file=sys.stderr)

        elif args.command == "doctor":
            key, endpoint = resolve_credentials(args.key, args.endpoint)
            run_doctor(endpoint, key)

        elif args.command == "query":
            piped_input = ""
            if not sys.stdin.isatty():
                piped_input = sys.stdin.read().strip()

            query_text = args.query_text
            if piped_input:
                if query_text:
                    query_text = f"{query_text}\n\n[Piped Context]:\n{piped_input}"
                else:
                    query_text = piped_input
            else:
                if not query_text:
                    print("Error: query_text is required if no input is piped.", file=sys.stderr)
                    sys.exit(1)

            key, _ = resolve_credentials(args.key)
            tenant_id = _resolve_tenant(args.tenant, key)
            run_query(query_text, as_json=args.json, tenant_id=tenant_id, limit=args.limit)


if __name__ == "__main__":
    main()
