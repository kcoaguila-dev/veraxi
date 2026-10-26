import json
import os
import sys

# Enable readline for terminal history and editing if available
try:
    import readline
except ImportError:
    pass

from veraxi.cli.query import run_query


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

            if query_text.lower() == "help":
                print(f"\n{yellow}Available Commands:{reset}")
                print("  Type any question or topic to search vectors & graph entities.")
                print("  clear       - Clear the terminal screen")
                print("  exit / quit - End this interactive session\n")
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
