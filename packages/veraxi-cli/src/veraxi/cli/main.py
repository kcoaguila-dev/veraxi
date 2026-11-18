import argparse
import os
import sys
from veraxi.cli.auth import resolve_credentials, run_login, run_logout, run_whoami
from veraxi.cli.chat import run_interactive_chat
from veraxi.cli.check import run_check
from veraxi.cli.client_configs import CLIENT_PATH_RESOLVERS, update_mcp_config
from veraxi.cli.cluster import run_cluster
from veraxi.cli.completion import run_completion
from veraxi.cli.config import load_cli_config, run_config
from veraxi.cli.context import run_context
from veraxi.cli.doctor import check_endpoint, run_doctor
from veraxi.cli.hook import run_hook
from veraxi.cli.impact import run_impact
from veraxi.cli.ingest import run_ingest
from veraxi.cli.init_project import init_project
from veraxi.cli.learn import run_learn
from veraxi.cli.memories import (
    run_memories_add,
    run_memories_delete,
    run_memories_edit,
    run_memories_expire,
    run_memories_list,
    run_memories_stats,
)
from veraxi.cli.models import run_models_list, run_models_set
from veraxi.cli.memory import (
    run_memory_audit,
    run_memory_export,
    run_memory_import,
    run_memory_list,
    run_memory_prune,
    run_memory_stats,
    run_remember,
    run_reopen,
    run_resolve,
)
from veraxi.cli.query import run_query
from veraxi.cli.review import run_review
from veraxi.cli.rules import run_rules_lint, run_rules_sync
from veraxi.cli.schema import run_schema
from veraxi.cli.stats import run_stats
from veraxi.cli.trace import run_trace
from veraxi.cli.code_intel import run_vuln_attack_sync, run_vuln_recon, run_vuln_report, run_vuln_sarif, run_vuln_sync, run_xray_impact, run_xray_index, run_xray_symbol
from veraxi.cli.corpus import run_briefing, run_dbt_lineage, run_dbt_upload
from veraxi.cli.evals import run_eval_ablation
from veraxi.cli.web import run_web


def _resolve_tenant_id(tenant_arg: str | None) -> str:
    """Resolves the tenant ID from non-secret sources only.

    Priority: explicit --tenant argument, VERAXI_TENANT_ID environment
    variable, "tenant_id" in ~/.veraxi/config.json, the configured admin
    tenant, then "default". The tenant ID is deliberately decoupled from
    API keys and the Supabase service key so no secret-derived value can
    flow into it (or into anything that prints it).
    """
    if tenant_arg:
        return tenant_arg

    env_tenant = os.environ.get("VERAXI_TENANT_ID")
    if env_tenant:
        return env_tenant

    try:
        file_tenant = load_cli_config().get("tenant_id")
        if file_tenant:
            return str(file_tenant)
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
    chat_parser.add_argument(
        "--tenant", help="Tenant ID (defaults to resolving from key or config)"
    )
    chat_parser.add_argument(
        "--limit", type=int, default=5, help="Number of evidence chunks to retrieve"
    )
    chat_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL"
    )
    chat_parser.add_argument(
        "--mode",
        choices=["fast", "deep"],
        default="fast",
        help="Execution mode: 'fast' (sub-second Hybrid GraphRAG) or 'deep' (Multi-Agent Research Swarm)",
    )
    chat_parser.add_argument("--model", help="Model name (used for Deep estimate pricing)")
    chat_parser.add_argument("--show-sources", action="store_true", help="Print provenance for each answer")
    chat_parser.add_argument("--json", action="store_true", help="Emit provenance as raw JSON with --show-sources / /sources")
    chat_parser.add_argument("--dry-run", action="store_true", help="Print the Deep estimate and exit (with --mode deep)")

    # --- init ---
    init_parser = subparsers.add_parser(
        "init",
        help="Initialize Veraxi knowledge graph instructions (CLAUDE.md & .cursorrules)",
    )
    init_parser.add_argument(
        "--force", action="store_true", help="Overwrite existing instructions"
    )

    # --- brief ---
    brief_parser = subparsers.add_parser(
        "brief",
        aliases=["research"],
        help="Generate a structured briefing doc on a topic with linked entity graph anchors",
    )
    brief_parser.add_argument("topic", nargs="?", help="Briefing topic or question")
    brief_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    brief_parser.add_argument(
        "--tenant", help="Tenant ID (defaults to resolving from key or config)"
    )
    brief_parser.add_argument(
        "--limit", type=int, default=10, help="Number of evidence chunks to retrieve"
    )
    brief_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL"
    )
    brief_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- review ---
    review_parser = subparsers.add_parser(
        "review", help="1-Command Git Diff Auditor & CI Rule Enforcer"
    )
    review_parser.add_argument(
        "--staged", action="store_true", help="Review staged changes"
    )
    review_parser.add_argument("--commit", help="Review a specific commit hash")
    review_parser.add_argument(
        "--enforce-rules",
        "--rules",
        dest="enforce_rules",
        action="store_true",
        help="Audit diff against active architectural rules and fail CI on violations",
    )
    review_parser.add_argument(
        "--strict", action="store_true", help="Exit code 1 on rule violations"
    )
    review_parser.add_argument("--project", help="Project repository scope")
    review_parser.add_argument(
        "--limit", type=int, default=10, help="Number of evidence chunks to retrieve"
    )
    review_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    review_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    review_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- ingest ---
    ingest_parser = subparsers.add_parser("ingest", help="CLI Document & URL Ingest")
    ingest_parser.add_argument("target", help="File, directory, or URL to ingest")
    ingest_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    ingest_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me", help="Veraxi API endpoint"
    )

    # --- login ---
    login_parser = subparsers.add_parser(
        "login", help="Authenticate and save API key locally"
    )
    login_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    login_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL"
    )

    # --- whoami ---
    whoami_parser = subparsers.add_parser(
        "whoami", help="Display current active identity & credentials"
    )
    whoami_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    whoami_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL"
    )

    # --- logout ---
    subparsers.add_parser("logout", help="Log out and remove stored credentials")

    # --- stats ---
    stats_parser = subparsers.add_parser(
        "stats", help="Display database & knowledge graph health dashboard"
    )
    stats_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    stats_parser.add_argument(
        "--tenant", help="Tenant ID (defaults to resolving from key or config)"
    )
    stats_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me", help="Veraxi API endpoint"
    )
    stats_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- completion ---
    completion_parser = subparsers.add_parser(
        "completion", help="Generate shell auto-completion script"
    )
    completion_parser.add_argument(
        "shell", choices=["bash", "zsh"], default="bash", nargs="?", help="Shell type"
    )

    # --- hook ---
    hook_parser = subparsers.add_parser(
        "hook",
        help="Manage Git pre-commit and post-commit hooks for review and auto-learning",
    )
    hook_parser.add_argument(
        "action",
        choices=["install", "uninstall"],
        default="install",
        nargs="?",
        help="Action to perform (default: install)",
    )
    hook_parser.add_argument(
        "--type",
        choices=["pre-commit", "post-commit", "all"],
        default="pre-commit",
        help="Hook type to manage (default: pre-commit)",
    )

    # --- learn ---
    learn_parser = subparsers.add_parser(
        "learn", help="Autonomously learn architectural rules from git commits"
    )
    learn_parser.add_argument(
        "commit",
        default="HEAD",
        nargs="?",
        help="Git commit to analyze (default: HEAD)",
    )
    learn_parser.add_argument(
        "--auto",
        action="store_true",
        help="Auto-capture without interactive prompt (for post-commit hook)",
    )
    learn_parser.add_argument(
        "-y", "--yes", action="store_true", help="Non-interactive confirm"
    )
    learn_parser.add_argument(
        "--sync",
        action="store_true",
        help="Automatically sync rules to AI editors after learning",
    )
    learn_parser.add_argument("--project", help="Project repository scope")
    learn_parser.add_argument("--tenant", help="Tenant ID")
    learn_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    learn_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    learn_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- schema ---
    schema_parser = subparsers.add_parser(
        "schema", help="Display knowledge graph ontology and schema"
    )
    schema_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    schema_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    schema_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- trace ---
    trace_parser = subparsers.add_parser(
        "trace", help="Trace multi-hop causal/dependency paths for an entity"
    )
    trace_parser.add_argument("entity", help="Entity or symbol name to trace")
    trace_parser.add_argument(
        "--hops", type=int, default=2, help="Max traversal depth (default: 2)"
    )
    trace_parser.add_argument("--tenant", help="Tenant ID")
    trace_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    trace_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    trace_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- check ---
    check_parser = subparsers.add_parser(
        "check", help="Grounding and factual accuracy gatekeeper for CI"
    )
    check_parser.add_argument(
        "text", nargs="?", help="Claim or text to verify against knowledge base"
    )
    check_parser.add_argument("--context", help="Explicit context string or file path")
    check_parser.add_argument(
        "--min-score",
        type=float,
        default=0.8,
        help="Minimum passing grounding threshold (default: 0.8)",
    )
    check_parser.add_argument("--tenant", help="Tenant ID")
    check_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    check_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    check_parser.add_argument("--json", action="store_true", help="Output raw JSON")
    check_parser.add_argument(
        "--peek",
        action="store_true",
        help="Peek exact lines from physical document page",
    )
    check_parser.add_argument(
        "--top-k",
        type=int,
        default=3,
        help="Number of evidence passages to retrieve (default: 3)",
    )

    # --- context ---
    context_parser = subparsers.add_parser(
        "context", help="Assemble token-efficient grounding context for agents"
    )
    context_parser.add_argument("task", nargs="?", help="Task or prompt description")
    context_parser.add_argument(
        "--project",
        help="Project repository scope (defaults to auto-detected git repo)",
    )
    context_parser.add_argument("--tenant", help="Tenant ID")
    context_parser.add_argument(
        "--limit", type=int, default=4, help="Max vector chunks to include"
    )
    context_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    context_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    context_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- remember ---
    remember_parser = subparsers.add_parser("remember")
    remember_parser.add_argument(
        "insight", help="The architectural rule, pattern, or constraint"
    )
    remember_parser.add_argument("--tag", help="Category tag (e.g., auth, perf, db)")
    remember_parser.add_argument(
        "--type",
        choices=["rule", "issue", "pattern"],
        default="rule",
        help="Type of memory",
    )
    remember_parser.add_argument(
        "--supersedes", help="ID or keyword of older memory this replaces"
    )
    remember_parser.add_argument(
        "--project",
        help="Project repository scope (defaults to auto-detected git repo)",
    )
    remember_parser.add_argument(
        "--global",
        dest="is_global",
        action="store_true",
        help="Apply across all projects",
    )
    remember_parser.add_argument(
        "--permanent",
        "--invariant",
        dest="is_invariant",
        action="store_true",
        help="Store as permanent architectural invariant (protected from pruning)",
    )
    remember_parser.add_argument("--tenant", help="Tenant ID")
    remember_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    remember_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    remember_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- resolve ---
    resolve_parser = subparsers.add_parser("resolve")
    resolve_parser.add_argument("target", help="Memory ID or keyword to resolve")
    resolve_parser.add_argument("--ref", help="Commit hash, PR number, or ticket")
    resolve_parser.add_argument("--note", help="Explanation of resolution")
    resolve_parser.add_argument("--tenant", help="Tenant ID")
    resolve_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    resolve_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    resolve_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- reopen ---
    reopen_parser = subparsers.add_parser("reopen")
    reopen_parser.add_argument("target", help="Memory ID or keyword to reopen")
    reopen_parser.add_argument(
        "--note", help="Reason for reopening (e.g. still failing)"
    )
    reopen_parser.add_argument("--tenant", help="Tenant ID")
    reopen_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    reopen_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    reopen_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- memory ---
    memory_parser = subparsers.add_parser("memory")
    memory_parser.add_argument(
        "action",
        choices=["list", "export", "import", "audit", "prune", "stats", "drift"],
        default="list",
        nargs="?",
        help="Action to perform",
    )
    memory_parser.add_argument(
        "file_path", nargs="?", help="File path for import or export"
    )
    memory_parser.add_argument(
        "--status",
        choices=["active", "resolved", "superseded", "all"],
        default="all",
        help="Status filter",
    )
    memory_parser.add_argument(
        "--project", help="Project repository filter (defaults to current git repo)"
    )
    memory_parser.add_argument(
        "--all-projects",
        action="store_true",
        help="Display memories across all projects",
    )
    memory_parser.add_argument(
        "--older-than",
        default="90d",
        help="Retention window for pruning (e.g. 30d, 90d)",
    )
    memory_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview items that would be pruned without modifying state",
    )
    memory_parser.add_argument(
        "--archive-file", help="Archive file destination for pruned items"
    )
    memory_parser.add_argument(
        "--output",
        "-o",
        help="Output file path for export (default: .veraxi/rules.json)",
    )
    memory_parser.add_argument(
        "--drift",
        action="store_true",
        help="Audit memories for codebase drift, orphaned targets, and upgraded dependencies",
    )
    memory_parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit code 1 if codebase drift is detected (for CI/CD)",
    )
    memory_parser.add_argument("--tenant", help="Tenant ID")
    memory_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    memory_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    memory_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- prune (alias to memory prune) ---
    prune_parser = subparsers.add_parser("prune")
    prune_parser.add_argument(
        "--older-than",
        default="90d",
        help="Retention window for pruning (e.g. 30d, 90d)",
    )
    prune_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview items that would be pruned without modifying state",
    )
    prune_parser.add_argument(
        "--status",
        choices=["resolved", "superseded", "all"],
        default="resolved",
        help="Status filter to prune",
    )
    prune_parser.add_argument("--project", help="Project repository filter")
    prune_parser.add_argument(
        "--all-projects", action="store_true", help="Prune across all projects"
    )
    prune_parser.add_argument("--archive-file", help="Archive destination file")
    prune_parser.add_argument("--tenant", help="Tenant ID")
    prune_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    prune_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    prune_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- rules ---
    rules_parser = subparsers.add_parser(
        "rules",
        help="Manage, lint, and sync rules with AI editors (CLAUDE.md, .cursorrules)",
    )
    rules_parser.add_argument(
        "action",
        choices=["sync", "list", "lint", "check"],
        default="sync",
        nargs="?",
        help="Rules action",
    )
    rules_parser.add_argument(
        "--target",
        choices=["claude", "cursor", "cline", "all"],
        default="all",
        help="Target AI tool",
    )
    rules_parser.add_argument("--project", help="Project repository scope")
    rules_parser.add_argument("--tenant", help="Tenant ID")
    rules_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    rules_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    rules_parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with code 1 if critical rule contradictions are found",
    )
    rules_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- sync (alias to rules sync) ---
    sync_parser = subparsers.add_parser(
        "sync",
        help="1-Command sync of architectural rules to CLAUDE.md, .cursorrules, .clinerules",
    )
    sync_parser.add_argument(
        "--target",
        choices=["claude", "cursor", "cline", "all"],
        default="all",
        help="Target AI tool",
    )
    sync_parser.add_argument("--project", help="Project repository scope")
    sync_parser.add_argument("--tenant", help="Tenant ID")
    sync_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    sync_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    sync_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- cluster ---
    cluster_parser = subparsers.add_parser(
        "cluster", help="Manage cross-repository microservice clusters"
    )
    cluster_parser.add_argument(
        "action",
        choices=["add", "list", "remove", "link"],
        default="list",
        nargs="?",
        help="Cluster action",
    )
    cluster_parser.add_argument(
        "name", nargs="?", help="Cluster name or target repo to link"
    )
    cluster_parser.add_argument(
        "repos", nargs="*", help="Repository names to include in cluster"
    )
    cluster_parser.add_argument("--tenant", help="Tenant ID")
    cluster_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    cluster_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    cluster_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- repo (alias to cluster) ---
    repo_parser = subparsers.add_parser(
        "repo", help="Manage repository registration and microservice clusters"
    )
    repo_parser.add_argument(
        "action",
        choices=["add", "list", "remove", "link"],
        default="list",
        nargs="?",
        help="Cluster/repo action",
    )
    repo_parser.add_argument(
        "name", nargs="?", help="Cluster name or target repo to link"
    )
    repo_parser.add_argument(
        "repos", nargs="*", help="Repository names to include in cluster"
    )
    repo_parser.add_argument("--tenant", help="Tenant ID")
    repo_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    repo_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    repo_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- impact ---
    impact_parser = subparsers.add_parser(
        "impact", help="Architectural blast radius analysis before refactoring"
    )
    impact_parser.add_argument(
        "target", help="Target symbol name, class, function, or file path"
    )
    impact_parser.add_argument(
        "--hops", type=int, default=2, help="Blast radius traversal depth (1-4)"
    )
    impact_parser.add_argument("--project", help="Explicit project name")
    impact_parser.add_argument("--tenant", help="Tenant ID")
    impact_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    impact_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint"
    )
    impact_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- mcp ---
    mcp_parser = subparsers.add_parser(
        "mcp", help="Manage MCP configurations and test queries"
    )
    mcp_subparsers = mcp_parser.add_subparsers(dest="command", help="MCP actions")

    # `veraxi mcp install ...`
    install_parser = mcp_subparsers.add_parser(
        "install", help="1-Click automatic MCP configuration"
    )
    install_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    install_parser.add_argument(
        "--client",
        choices=["claude", "cursor", "claude-code", "cline", "all"],
        default="all",
        help="Which client to configure",
    )
    install_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL"
    )
    install_parser.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Auto-approve prompts for headless scripts",
    )

    # `veraxi mcp doctor ...`
    doctor_parser = mcp_subparsers.add_parser(
        "doctor", help="Run connectivity and configuration diagnosis"
    )
    doctor_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    doctor_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL"
    )

    # `veraxi mcp query ...`
    query_parser = mcp_subparsers.add_parser(
        "query", help="Command-line test runner for headless agents"
    )
    query_parser.add_argument("query_text", nargs="?", help="The query string")
    query_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    query_parser.add_argument(
        "--tenant", help="Tenant ID (defaults to resolving from key or config)"
    )
    query_parser.add_argument(
        "--limit", type=int, default=5, help="Number of chunks to retrieve"
    )
    query_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL"
    )
    query_parser.add_argument(
        "--json", action="store_true", help="Output raw JSON for pipeline integration"
    )

    # --- config ---
    config_parser = subparsers.add_parser(
        "config", help="Manage CLI settings, endpoints, and provider API keys"
    )
    config_parser.add_argument(
        "action",
        nargs="?",
        default="list",
        choices=["list", "get", "set", "unset"],
        help="Config action (default: list)",
    )
    config_parser.add_argument(
        "key", nargs="?", help="Setting key name (e.g. default_model, openai_api_key)"
    )
    config_parser.add_argument(
        "value", nargs="?", help="Setting value (when using 'set')"
    )
    config_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- models ---
    models_parser = subparsers.add_parser(
        "models", help="Discover supported AI providers and select default models"
    )
    models_parser.add_argument(
        "action",
        nargs="?",
        default="list",
        choices=["list", "set"],
        help="Action: list (default) or set",
    )
    models_parser.add_argument(
        "model_name", nargs="?", help="Model name (when using 'set', e.g. gpt-4o)"
    )
    models_parser.add_argument(
        "--provider",
        help="Filter by provider (e.g. openai, anthropic, gemini, groq, ollama)",
    )
    models_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- doctor (top-level alias) ---
    top_doctor_parser = subparsers.add_parser(
        "doctor", help="Run system, environment, and connectivity diagnosis"
    )
    top_doctor_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    top_doctor_parser.add_argument(
        "--endpoint", default="https://api.veraxi.me/sse", help="MCP endpoint URL"
    )

    # --- web ---
    web_parser = subparsers.add_parser(
        "web", help="Multi-provider web search & page reader for agents and Termux"
    )
    web_parser.add_argument(
        "action",
        choices=["search", "fetch", "provider"],
        help="Action: search, fetch, or provider",
    )
    web_parser.add_argument(
        "query_or_url",
        nargs="?",
        help="Search query, URL to fetch, or provider action (e.g. 'set')",
    )
    web_parser.add_argument(
        "provider_name",
        nargs="?",
        help="Provider name when using 'provider set <name>'",
    )
    web_parser.add_argument(
        "--provider",
        help="Override search provider (duckduckgo, searxng, serper, tavily)",
    )
    web_parser.add_argument(
        "--limit",
        type=int,
        default=5,
        help="Maximum number of search results (default: 5)",
    )
    web_parser.add_argument(
        "--json", action="store_true", help="Output raw JSON for agent pipelines"
    )

    # --- eval ---
    eval_parser = subparsers.add_parser("eval", help="Evidence evals (ablation)")
    eval_sub = eval_parser.add_subparsers(dest="eval_command")
    abl_parser = eval_sub.add_parser("ablation", help="Run typed ablation (offline by default)")
    abl_parser.add_argument("--dataset", required=True, help="Typed dataset JSON")
    abl_parser.add_argument("--rankings", required=True, help="Recorded rankings JSON")
    abl_parser.add_argument("--k", type=int, default=5)
    abl_parser.add_argument("--json", action="store_true", help="Output raw JSON")
    abl_parser.add_argument("--out-markdown", dest="out_markdown", help="Write markdown report")
    abl_parser.add_argument("--remote", action="store_true", help="Post to /api/v1/evals/ablation instead of offline")
    abl_parser.add_argument("--min-recall", type=float, dest="min_recall")
    abl_parser.add_argument("--min-hit-rate", type=float, dest="min_hit_rate")
    abl_parser.add_argument("--min-grounding", type=float, dest="min_grounding")
    abl_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    abl_parser.add_argument("--tenant", help="Tenant ID")
    abl_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")

    # --- xray ---
    xray_parser = subparsers.add_parser("xray", help="Repo X-Ray code graph")
    xray_sub = xray_parser.add_subparsers(dest="xray_command")
    for _name, _help in (("index", "Index a repo into the code graph"), ("symbol", "Look up a symbol"), ("impact", "Impact analysis for a symbol")):
        _sp = xray_sub.add_parser(_name, help=_help)
        _sp.add_argument("target", help="Repo path (index) or symbol name")
        _sp.add_argument("--max-depth", type=int, default=3, dest="max_depth")
        _sp.add_argument("--local", action="store_true", help="Index: parse the repo locally and upload the graph")
        _sp.add_argument("--resolved-only", action="store_true", dest="resolved_only", help="Symbol: hide external/unresolved placeholders")
        _sp.add_argument("--key", help="Veraxi API key (vx-...)")
        _sp.add_argument("--tenant", help="Tenant ID")
        _sp.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
        _sp.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- vuln ---
    vuln_parser = subparsers.add_parser("vuln", help="Vulnerability intel (NVD + CISA KEV)")
    vuln_sub = vuln_parser.add_subparsers(dest="vuln_command")
    _sync = vuln_sub.add_parser("sync", help="Sync NVD + CISA KEV intel")
    _sync.add_argument("--key", help="Veraxi API key (vx-...)")
    _sync.add_argument("--tenant", help="Tenant ID")
    _sync.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    _sync.add_argument("--json", action="store_true", help="Output raw JSON")
    _rep = vuln_sub.add_parser("report", help="Vuln report for a repo or deps file")
    _rep.add_argument("repo_path", nargs="?", help="Repo path (server allowlist applies)")
    _rep.add_argument("--deps", help="JSON file of dependencies [{name, version, ...}]")
    _rep.add_argument("--sbom", help="CycloneDX or SPDX JSON SBOM file")
    _rep.add_argument("--local", action="store_true", help="Extract dependencies locally and upload the list")
    _rep.add_argument("--live-osv", action="store_true", dest="live_osv", help="Query OSV.dev live when the graph has no findings")
    _rep.add_argument("--reachability", action="store_true", help="Cross-reference vulnerable packages against Repo X-Ray code graph")
    _rep.add_argument("--fail-on", dest="fail_on", choices=["high", "critical"], help="Exit 2 if a finding is at/above this severity")
    _rep.add_argument("--key", help="Veraxi API key (vx-...)")
    _rep.add_argument("--tenant", help="Tenant ID")
    _rep.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    _rep.add_argument("--json", action="store_true", help="Output raw JSON")
    _sarif = vuln_sub.add_parser("sarif", help="Upload a SARIF 2.1.0 SAST file (Semgrep, Trivy, CodeQL)")
    _sarif.add_argument("sarif_path", help="Path to SARIF JSON file")
    _sarif.add_argument("--key", help="Veraxi API key (vx-...)")
    _sarif.add_argument("--tenant", help="Tenant ID")
    _sarif.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    _sarif.add_argument("--json", action="store_true", help="Output raw JSON")
    _atk = vuln_sub.add_parser("attack-sync", help="Sync MITRE ATT&CK (STIX 2.1)")
    _atk.add_argument("--stix", help="Optional local STIX 2.1 JSON bundle")
    _atk.add_argument("--key", help="Veraxi API key (vx-...)")
    _atk.add_argument("--tenant", help="Tenant ID")
    _atk.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    _atk.add_argument("--json", action="store_true", help="Output raw JSON")
    _rec = vuln_sub.add_parser("recon", help="Upload a Nuclei JSON/JSONL recon file")
    _rec.add_argument("nuclei_path", help="Path to Nuclei JSON or JSONL file")
    _rec.add_argument("--key", help="Veraxi API key (vx-...)")
    _rec.add_argument("--tenant", help="Tenant ID")
    _rec.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    _rec.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- briefing ---
    briefing_parser = subparsers.add_parser("briefing", help="Corpus briefing (Knowledge Hub)")
    briefing_parser.add_argument("--out", help="Write markdown briefing to this file")
    briefing_parser.add_argument("--key", help="Veraxi API key (vx-...)")
    briefing_parser.add_argument("--tenant", help="Tenant ID")
    briefing_parser.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    briefing_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- dbt ---
    dbt_parser = subparsers.add_parser("dbt", help="dbt manifest ingest and lineage")
    dbt_sub = dbt_parser.add_subparsers(dest="dbt_command")
    _up = dbt_sub.add_parser("upload", help="Upload a dbt manifest.json")
    _up.add_argument("manifest", help="Path to manifest.json")
    _up.add_argument("--key", help="Veraxi API key (vx-...)")
    _up.add_argument("--tenant", help="Tenant ID")
    _up.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    _up.add_argument("--json", action="store_true", help="Output raw JSON")
    _lin = dbt_sub.add_parser("lineage", help="Dataset/column lineage search")
    _lin.add_argument("target", help="Dataset name fragment or exact column name")
    _lin.add_argument("--key", help="Veraxi API key (vx-...)")
    _lin.add_argument("--tenant", help="Tenant ID")
    _lin.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
    _lin.add_argument("--json", action="store_true", help="Output raw JSON")

    # --- memories (Supabase user_memories — the memory store going forward) ---
    memories_parser = subparsers.add_parser(
        "memories",
        help="User memories (Supabase user_memories, SSOT going forward; legacy Neo4j 'memory'/'remember' are deprecated)",
        description="Per-user memories in Supabase user_memories (temporal valid_to) — the single source of truth going forward. Legacy Neo4j-backed 'veraxi memory'/'remember' (project-scoped agent rules) are deprecated; there is no data to migrate and no dual-write.",
    )
    memories_sub = memories_parser.add_subparsers(dest="memories_command")
    _ml = memories_sub.add_parser("list", help="List memories (expired hidden unless --all)")
    _ml.add_argument("--all", action="store_true", dest="include_all", help="Also show expired memories with valid_to")
    _ma = memories_sub.add_parser("add", help="Add a memory")
    _ma.add_argument("content", help="Memory content")
    _ma.add_argument("--source", default="manual", choices=["chat", "manual", "import"])
    _me = memories_sub.add_parser("edit", help="Edit a memory")
    _me.add_argument("memory_id", help="Memory ID")
    _me.add_argument("--content", help="New content")
    _me.add_argument("--source", choices=["chat", "manual", "import"])
    _mx = memories_sub.add_parser("expire", help="Expire a memory (sets valid_to; row retained)")
    _mx.add_argument("memory_id", help="Memory ID")
    _md = memories_sub.add_parser("delete", help="Delete a memory (row removed)")
    _md.add_argument("memory_id", help="Memory ID")
    _ms = memories_sub.add_parser("stats", help="Show memory counts (active/expired) in user_memories")
    for _sp in (_ml, _ma, _me, _mx, _md, _ms):
        _sp.add_argument("--key", help="Veraxi API key (vx-...)")
        _sp.add_argument("--tenant", help="Tenant ID")
        _sp.add_argument("--endpoint", default="https://api.veraxi.me/sse", help="Veraxi API endpoint")
        _sp.add_argument("--json", action="store_true", help="Output raw JSON")

    args = parser.parse_args()

    if not args.subcommand:
        # Default to interactive chat if run directly in an interactive shell
        if sys.stdin.isatty():
            tenant_id = _resolve_tenant_id(None)
            key, endpoint = resolve_credentials()
            run_interactive_chat(
                tenant_id=tenant_id,
                endpoint=endpoint,
                key=key,
                mode=getattr(args, "mode", "fast"),
            )
        else:
            parser.print_help()
        sys.exit(0)

    if args.subcommand == "login":
        run_login(key=args.key, endpoint=args.endpoint)

    elif args.subcommand == "whoami":
        run_whoami(key=args.key, endpoint=args.endpoint)

    elif args.subcommand == "logout":
        run_logout()

    elif args.subcommand == "stats":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_stats(tenant_id=tenant_id, endpoint=endpoint, key=key, as_json=args.json)

    elif args.subcommand == "completion":
        run_completion(shell=args.shell)

    elif args.subcommand == "hook":
        run_hook(action=args.action, hook_type=getattr(args, "type", "pre-commit"))

    elif args.subcommand == "learn":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_learn(
            commit=args.commit,
            auto=args.auto,
            yes=args.yes,
            sync=args.sync,
            project=args.project,
            tenant_id=tenant_id,
            as_json=args.json,
        )

    elif args.subcommand == "schema":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        run_schema(endpoint=endpoint, key=key, as_json=args.json)

    elif args.subcommand == "trace":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_trace(
            entity=args.entity,
            hops=args.hops,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.subcommand == "check":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_check(
            text=args.text,
            context=args.context,
            min_score=args.min_score,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
            peek=getattr(args, "peek", False),
            top_k=getattr(args, "top_k", 3),
        )

    elif args.subcommand == "context":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_context(
            task=args.task,
            project=args.project,
            tenant_id=tenant_id,
            limit=args.limit,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.subcommand == "remember":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        mem_type = "invariant" if getattr(args, "is_invariant", False) else args.type
        run_remember(
            insight=args.insight,
            tag=args.tag,
            memory_type=mem_type,
            supersedes=args.supersedes,
            project=args.project,
            is_global=args.is_global,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.subcommand == "resolve":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_resolve(
            target=args.target,
            ref=args.ref,
            note=args.note,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.subcommand == "reopen":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_reopen(
            target=args.target,
            note=args.note,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.subcommand == "memory":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        action = getattr(args, "action", "list") or "list"
        if action == "export":
            run_memory_export(
                output_path=getattr(args, "output", None)
                or getattr(args, "file_path", None),
                project=args.project,
                all_projects=args.all_projects,
                tenant_id=tenant_id,
                endpoint=endpoint,
                key=key,
                as_json=args.json,
            )
        elif action == "import":
            run_memory_import(
                file_path=getattr(args, "file_path", None),
                project=args.project,
                tenant_id=tenant_id,
                endpoint=endpoint,
                key=key,
                as_json=args.json,
            )
        elif action in ("audit", "drift"):
            run_memory_audit(
                project=args.project,
                tenant_id=tenant_id,
                endpoint=endpoint,
                key=key,
                as_json=args.json,
                drift=getattr(args, "drift", False) or action == "drift",
                strict=getattr(args, "strict", False),
            )
        elif action == "prune":
            run_memory_prune(
                older_than=getattr(args, "older_than", "90d"),
                dry_run=getattr(args, "dry_run", False),
                archive_file=getattr(args, "archive_file", None),
                status_filter=getattr(args, "status", "resolved"),
                project=args.project,
                all_projects=args.all_projects,
                tenant_id=tenant_id,
                endpoint=endpoint,
                key=key,
                as_json=args.json,
            )
        elif action == "stats":
            run_memory_stats(
                project=args.project,
                all_projects=args.all_projects,
                tenant_id=tenant_id,
                endpoint=endpoint,
                key=key,
                as_json=args.json,
            )
        else:
            run_memory_list(
                status_filter=args.status,
                project=args.project,
                all_projects=args.all_projects,
                tenant_id=tenant_id,
                endpoint=endpoint,
                key=key,
                as_json=args.json,
            )

    elif args.subcommand in ("rules", "sync"):
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        action = getattr(args, "action", "sync")
        if action in ("lint", "check"):
            run_rules_lint(
                project=args.project,
                tenant_id=tenant_id,
                strict=getattr(args, "strict", False),
                as_json=args.json,
            )
        else:
            run_rules_sync(
                target=args.target,
                project=args.project,
                tenant_id=tenant_id,
                endpoint=endpoint,
                key=key,
                as_json=args.json,
            )

    elif args.subcommand in ("cluster", "repo"):
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_cluster(
            action=args.action,
            name=args.name,
            repos=args.repos,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.subcommand == "impact":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_impact(
            target=args.target,
            hops=args.hops,
            project=args.project,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.subcommand == "prune":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_memory_prune(
            older_than=getattr(args, "older_than", "90d"),
            dry_run=getattr(args, "dry_run", False),
            archive_file=getattr(args, "archive_file", None),
            status_filter=getattr(args, "status", "resolved"),
            project=args.project,
            all_projects=args.all_projects,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            as_json=args.json,
        )

    elif args.subcommand == "chat":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_interactive_chat(
            tenant_id=tenant_id,
            limit=args.limit,
            endpoint=endpoint,
            key=key,
            model=getattr(args, "model", None),
            mode=getattr(args, "mode", "fast"),
            show_sources=getattr(args, "show_sources", False),
            as_json=getattr(args, "json", False),
            dry_run=getattr(args, "dry_run", False),
        )

    elif args.subcommand == "init":
        init_project(force=args.force)

    elif args.subcommand in ("brief", "research"):
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

        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_query(
            topic,
            as_json=args.json,
            tenant_id=tenant_id,
            limit=args.limit,
            endpoint=endpoint,
            key=key,
        )

    elif args.subcommand == "review":
        key, endpoint = resolve_credentials(args.key, getattr(args, "endpoint", None))
        tenant_id = _resolve_tenant_id(None)
        run_review(
            staged=args.staged,
            commit_hash=args.commit,
            limit=args.limit,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            enforce_rules=getattr(args, "enforce_rules", False),
            project=getattr(args, "project", None),
            strict=getattr(args, "strict", False),
            as_json=getattr(args, "json", False),
        )

    elif args.subcommand == "ingest":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        run_ingest(
            target=args.target,
            key=key,
            endpoint=endpoint,
        )

    elif args.subcommand == "mcp":
        if not args.command:
            mcp_parser.print_help()
            sys.exit(0)

        if args.command == "install":
            key, endpoint = resolve_credentials(args.key, args.endpoint)
            is_headless = not sys.stdin.isatty()

            if not key and not is_headless:
                key = input("Enter your Veraxi API Key: ").strip()

            if not key and is_headless:
                print(
                    "Error: Headless environment detected. Please provide --key, set VERAXI_API_KEY, or run 'veraxi login'.",
                    file=sys.stderr,
                )
                sys.exit(1)

            if not key:
                print("Error: No API key provided.", file=sys.stderr)
                sys.exit(1)

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
                    print(
                        "Error: query_text is required if no input is piped.",
                        file=sys.stderr,
                    )
                    sys.exit(1)

            key, endpoint = resolve_credentials(args.key, args.endpoint)
            tenant_id = _resolve_tenant_id(args.tenant)
            run_query(
                query_text,
                as_json=args.json,
                tenant_id=tenant_id,
                limit=args.limit,
                endpoint=endpoint,
                key=key,
            )

    elif args.subcommand == "config":
        run_config(
            action=args.action,
            key=args.key,
            value=args.value,
            as_json=args.json,
        )

    elif args.subcommand == "models":
        if getattr(args, "action", "list") == "set":
            run_models_set(model_name=args.model_name)
        else:
            run_models_list(
                provider_filter=args.provider,
                as_json=args.json,
            )

    elif args.subcommand == "doctor":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        run_doctor(endpoint, key)

    elif args.subcommand == "eval":
        if getattr(args, "eval_command", None) != "ablation":
            parser.parse_args(["eval", "--help"])
            sys.exit(0)
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_eval_ablation(
            dataset=args.dataset, rankings=args.rankings, k=args.k, as_json=args.json,
            out_markdown=args.out_markdown, remote=args.remote, endpoint=endpoint, key=key,
            tenant=tenant_id, min_recall=args.min_recall, min_hit_rate=args.min_hit_rate,
            min_grounding=args.min_grounding,
        )

    elif args.subcommand == "xray":
        if getattr(args, "xray_command", None) not in ("index", "symbol", "impact"):
            parser.parse_args(["xray", "--help"])
            sys.exit(0)
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        if args.xray_command == "index":
            run_xray_index(args.target, endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json, local=getattr(args, "local", False))
        elif args.xray_command == "symbol":
            run_xray_symbol(args.target, endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json, resolved_only=getattr(args, "resolved_only", False))
        else:
            run_xray_impact(args.target, endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json, max_depth=args.max_depth)

    elif args.subcommand == "vuln":
        if getattr(args, "vuln_command", None) not in ("sync", "report", "sarif", "attack-sync", "recon"):
            parser.parse_args(["vuln", "--help"])
            sys.exit(0)
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        if args.vuln_command == "sync":
            run_vuln_sync(endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json)
        elif args.vuln_command == "sarif":
            run_vuln_sarif(
                args.sarif_path,
                endpoint=endpoint,
                key=key,
                tenant=tenant_id,
                as_json=args.json,
            )
        elif args.vuln_command == "attack-sync":
            run_vuln_attack_sync(
                stix_path=getattr(args, "stix", None),
                endpoint=endpoint,
                key=key,
                tenant=tenant_id,
                as_json=args.json,
            )
        elif args.vuln_command == "recon":
            run_vuln_recon(
                args.nuclei_path,
                endpoint=endpoint,
                key=key,
                tenant=tenant_id,
                as_json=args.json,
            )
        else:
            run_vuln_report(
                repo_path=args.repo_path,
                deps=args.deps,
                sbom=getattr(args, "sbom", None),
                endpoint=endpoint,
                key=key,
                tenant=tenant_id,
                as_json=args.json,
                fail_on=args.fail_on,
                live_osv=getattr(args, "live_osv", False),
                local=getattr(args, "local", False),
                reachability=getattr(args, "reachability", False),
            )

    elif args.subcommand == "briefing":
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        run_briefing(endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json, out=args.out)

    elif args.subcommand == "dbt":
        if getattr(args, "dbt_command", None) not in ("upload", "lineage"):
            parser.parse_args(["dbt", "--help"])
            sys.exit(0)
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        if args.dbt_command == "upload":
            run_dbt_upload(args.manifest, endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json)
        else:
            run_dbt_lineage(args.target, endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json)

    elif args.subcommand == "memories":
        if getattr(args, "memories_command", None) not in ("list", "add", "edit", "expire", "delete", "stats"):
            parser.parse_args(["memories", "--help"])
            sys.exit(0)
        key, endpoint = resolve_credentials(args.key, args.endpoint)
        tenant_id = _resolve_tenant_id(args.tenant)
        if args.memories_command == "list":
            run_memories_list(endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json, include_all=args.include_all)
        elif args.memories_command == "add":
            run_memories_add(args.content, endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json, source=args.source)
        elif args.memories_command == "edit":
            run_memories_edit(args.memory_id, content=args.content, source=args.source, endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json)
        elif args.memories_command == "expire":
            run_memories_expire(args.memory_id, endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json)
        elif args.memories_command == "stats":
            run_memories_stats(endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json)
        else:
            run_memories_delete(args.memory_id, endpoint=endpoint, key=key, tenant=tenant_id, as_json=args.json)

    elif args.subcommand == "web":
        run_web(
            action=args.action,
            query_or_url=args.query_or_url,
            provider_name=getattr(args, "provider_name", None),
            provider=getattr(args, "provider", None),
            limit=args.limit,
            as_json=args.json,
        )


if __name__ == "__main__":
    main()
