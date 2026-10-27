import os

# Enable readline for terminal history and editing if available
try:
    import readline
    _ = readline
except ImportError:
    pass

from veraxi.cli.models import run_models_list
from veraxi.cli.query import run_query
from veraxi.cli.stats import run_stats
from veraxi.cli.trace import run_trace
from veraxi.cli.web import run_web


def run_interactive_chat(
    tenant_id: str = "default",
    limit: int = 5,
    endpoint: str = "https://api.veraxi.me/sse",
    key: str | None = None,
):
    """
    Launches an interactive Terminal Knowledge Assistant REPL.
    Allows continuous conversational queries against the tenant's knowledge graph.
    """
    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    yellow = "\033[33m"
    dim = "\033[2m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║           Veraxi Terminal Knowledge Assistant (v0.1.0)             ║{reset}")
    print(f"{bold}{cyan}║    Two-Tier Just-In-Time GraphRAG • Domain Intelligence Engine     ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")
    print(f"{dim}Tenant ID: {tenant_id} | Endpoint: {endpoint}{reset}")
    print(f"{dim}Commands: 'exit' or 'quit' to leave, 'clear' to clear screen.{reset}\n")

    while True:
        try:
            prompt_str = f"{bold}{green}veraxi>{reset} "
            query_text = input(prompt_str).strip()

            if not query_text:
                continue

            if query_text.lower() in ("exit", "quit", "q"):
                print(f"{dim}Session ended.{reset}\n")
                break

            if query_text.lower() == "clear":
                os.system("clear" if os.name != "nt" else "cls")
                continue

            if query_text.lower() in ("help", "/help", "?"):
                print(f"\n{yellow}Available Commands & Shortcuts:{reset}")
                print("  <question>      - Query knowledge graph & vector memory")
                print("  /web <query>    - Search the live web via DuckDuckGo")
                print("  /fetch <url>    - Read clean Markdown from a web page")
                print("  /trace <entity> - Trace multi-hop causal graph relationships")
                print("  /stats          - Display knowledge graph counts & telemetry")
                print("  /models         - List supported AI models & provider readiness")
                print("  clear           - Clear the terminal screen")
                print("  exit / quit     - End this interactive session\n")
                continue

            if query_text.startswith("/web "):
                search_q = query_text[5:].strip()
                run_web(action="search", query_or_url=search_q, limit=limit)
                continue

            if query_text.startswith("/fetch "):
                fetch_url = query_text[7:].strip()
                run_web(action="fetch", query_or_url=fetch_url)
                continue

            if query_text.startswith("/trace "):
                entity_name = query_text[7:].strip()
                run_trace(entity_name=entity_name, tenant_id=tenant_id, endpoint=endpoint, key=key)
                continue

            if query_text.lower() in ("/stats", "stats"):
                run_stats(tenant_id=tenant_id, endpoint=endpoint, key=key)
                continue

            if query_text.lower() in ("/models", "/model", "models"):
                run_models_list()
                continue

            print()
            run_query(
                query_text,
                as_json=False,
                tenant_id=tenant_id,
                limit=limit,
                endpoint=endpoint,
                key=key,
            )
            print()

        except (KeyboardInterrupt, EOFError):
            print(f"\n{dim}Session interrupted. Exiting.{reset}\n")
            break
