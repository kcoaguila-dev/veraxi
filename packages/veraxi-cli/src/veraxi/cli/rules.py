import datetime
import json
import os
import re
import sys
from veraxi.cli.cluster import get_cluster_repos
from veraxi.cli.memory import _resolve_project_scope

MANAGED_START = "<!-- VERAXI_MANAGED_START (DO NOT EDIT DIRECTLY) -->"
MANAGED_END = "<!-- VERAXI_MANAGED_END -->"


def _get_utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def _get_active_rules(project_scope: str, tenant_id: str = "default") -> list[dict]:
    """
    Fetches active rules for the current project, its microservice cluster, and global scope.
    """
    sister_repos = get_cluster_repos(project_scope, tenant_id=tenant_id)
    all_scoped = set(sister_repos)
    all_scoped.add(project_scope)
    all_scoped.add("global")

    rules = []
    # 1. Try Neo4j Knowledge Graph
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        query = """
        MATCH (n:Memory)
        WHERE (n.tenant_id = $tenant_id OR n.tenant_id = 'default')
          AND n.status = 'active'
          AND (n.project IN $repos OR n.project = 'global' OR n.project IS NULL)
        RETURN n.id as id, n.name as name, n.tag as tag, n.type as type, n.project as project
        ORDER BY n.created_at ASC
        """
        rows = neo4j.execute_read(query, {"tenant_id": tenant_id, "repos": list(all_scoped)})
        neo4j.close()
        for r in rows:
            rules.append({
                "id": r.get("id"),
                "name": r.get("name"),
                "tag": r.get("tag", "rule"),
                "type": r.get("type", "rule"),
                "project": r.get("project", project_scope),
            })
    except Exception:
        pass

    # 2. Offline fallback: check local .veraxi/rules.json if present
    if not rules:
        local_file = os.path.join(os.getcwd(), ".veraxi", "rules.json")
        if os.path.isfile(local_file):
            try:
                with open(local_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    for item in data.get("memories", []):
                        if item.get("status") == "active":
                            proj = item.get("project")
                            if proj in all_scoped or proj == "global" or not proj:
                                rules.append(item)
            except Exception:
                pass

    return rules


def _inject_rules_block(content: str, block: str) -> str:
    """
    Replaces existing managed block or appends to content.
    """
    pattern = re.compile(
        re.escape(MANAGED_START) + r".*?" + re.escape(MANAGED_END),
        re.DOTALL,
    )
    if pattern.search(content):
        return pattern.sub(block, content)
    else:
        if content.strip():
            return content.rstrip() + "\n\n" + block + "\n"
        return block + "\n"


def run_rules_sync(
    target: str = "all",
    project: str | None = None,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Synchronizes active architectural constraints from the knowledge graph into
    AI editor configuration files (CLAUDE.md, .cursorrules, .clinerules, .cursor/rules/veraxi.mdc).
    """
    project_scope = _resolve_project_scope(project)
    active_rules = _get_active_rules(project_scope, tenant_id=tenant_id)

    # Build the managed markdown block
    now_str = _get_utc_now()
    lines = [MANAGED_START, f"## 🧠 Veraxi Architectural Constraints ({project_scope})", f"*Last synced: {now_str}* | Managed by `vx rules sync`\n"]

    if not active_rules:
        lines.append("*No active architectural constraints found. Run `vx remember \"<rule>\"` to add one.*")
    else:
        for r in active_rules:
            proj = r.get("project") or project_scope
            source_info = f" *(from {proj})*" if proj and str(proj).lower() not in (project_scope.lower(), "global", "none") else ""
            tag = r.get("tag", "rule")
            lines.append(f"- **[{tag}]** {r['name']}{source_info}")

    lines.append(MANAGED_END)
    block = "\n".join(lines)

    target = (target or "all").strip().lower()
    root_dir = os.getcwd()
    try:
        import subprocess
        root_dir = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        pass

    target_files = []
    if target in ("claude", "all"):
        target_files.append(os.path.join(root_dir, "CLAUDE.md"))
    if target in ("cursor", "all"):
        target_files.append(os.path.join(root_dir, ".cursorrules"))
        cursor_dir = os.path.join(root_dir, ".cursor", "rules")
        os.makedirs(cursor_dir, exist_ok=True)
        target_files.append(os.path.join(cursor_dir, "veraxi.mdc"))
    if target in ("cline", "all"):
        target_files.append(os.path.join(root_dir, ".clinerules"))

    updated_files = []
    for fpath in target_files:
        try:
            current_content = ""
            if os.path.isfile(fpath):
                with open(fpath, "r", encoding="utf-8") as f:
                    current_content = f.read()

            new_content = _inject_rules_block(current_content, block)
            with open(fpath, "w", encoding="utf-8") as f:
                f.write(new_content)
            updated_files.append(os.path.relpath(fpath, root_dir))
        except Exception as e:
            print(f"Warning: could not update {fpath}: {e}", file=sys.stderr)

    if as_json:
        print(json.dumps({
            "project": project_scope,
            "rules_count": len(active_rules),
            "updated_files": updated_files,
            "rules": active_rules,
        }, indent=2))
        return

    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi AI Editor Rules Synchronization             ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")

    print(f"\n  Project: {bold}{project_scope}{reset}")
    print(f"  {green}✓ Synchronized {len(active_rules)} active constraint(s) across {len(updated_files)} AI config file(s):{reset}")
    for f in updated_files:
        print(f"    • {bold}{f}{reset}")

    print("\n  AI coding agents (Claude Code, Cursor, Cline) now have immediate access")
    print("  to current architectural constraints without token-flooding on resolved issues.\n")
