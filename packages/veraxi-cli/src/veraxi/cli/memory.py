import datetime
import json
import os
import subprocess
import sys
import uuid


def _get_utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _resolve_project_scope(explicit_project: str | None = None) -> str:
    if explicit_project and explicit_project.strip():
        return explicit_project.strip()

    curr = os.getcwd()
    while curr != os.path.dirname(curr):
        cfg_file = os.path.join(curr, ".veraxi", "config.json")
        if os.path.isfile(cfg_file):
            try:
                with open(cfg_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if "project" in data and data["project"]:
                        return str(data["project"]).strip()
            except Exception:
                pass
        curr = os.path.dirname(curr)

    try:
        toplevel = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return os.path.basename(toplevel)
    except Exception:
        pass

    return os.path.basename(os.getcwd())


def run_remember(
    insight: str,
    tag: str | None = None,
    memory_type: str = "rule",
    supersedes: str | None = None,
    project: str | None = None,
    is_global: bool = False,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Stores an architectural rule, decision, or known constraint into the knowledge graph.
    Prevents cross-project memory contamination by scoping memories to the local project repository or global.
    """
    if not insight or not insight.strip():
        print("Error: insight text is required.", file=sys.stderr)
        sys.exit(1)

    insight = insight.strip()
    tag = (tag or "general").strip().lower()
    memory_type = (memory_type or "rule").strip().lower()
    project_scope = "global" if is_global else _resolve_project_scope(project)
    now_iso = _get_utc_now()
    mem_id = str(uuid.uuid4())[:8]

    superseded_nodes = []

    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        # Handle superseding within project scope or global
        if supersedes:
            find_query = """
            MATCH (old:Memory)
            WHERE (old.tenant_id = $tenant_id OR old.tenant_id = 'default')
              AND (old.project = $project OR old.project = 'global' OR old.project IS NULL)
              AND old.status = 'active'
              AND (toLower(old.name) CONTAINS toLower($supersedes) OR old.id STARTS WITH $supersedes)
            SET old.status = 'superseded', old.superseded_by = $new_id, old.superseded_at = $now_iso
            RETURN old.id as id, old.name as name
            """
            superseded_nodes = neo4j.execute_read(
                find_query,
                {"tenant_id": tenant_id, "project": project_scope, "supersedes": supersedes, "new_id": mem_id, "now_iso": now_iso},
            )

        create_query = """
        CREATE (n:Memory {
            id: $id,
            name: $name,
            details: $name,
            tag: $tag,
            type: $type,
            status: 'active',
            project: $project,
            tenant_id: $tenant_id,
            created_at: $created_at,
            resolved_ref: '',
            resolved_note: '',
            superseded_by: ''
        })
        RETURN n.id as id
        """
        neo4j.execute_write(
            create_query,
            {
                "id": mem_id,
                "name": insight,
                "tag": tag,
                "type": memory_type,
                "project": project_scope,
                "tenant_id": tenant_id,
                "created_at": now_iso,
            },
        )

        for s in superseded_nodes:
            link_query = """
            MATCH (new:Memory {id: $new_id})
            MATCH (old:Memory {id: $old_id})
            CREATE (new)-[:SUPERSEDES]->(old)
            """
            neo4j.execute_write(link_query, {"new_id": mem_id, "old_id": s["id"]})

        neo4j.close()
    except Exception as e:
        print(f"Warning: Local storage write failed ({e}).", file=sys.stderr)

    result_data = {
        "id": mem_id,
        "insight": insight,
        "tag": tag,
        "type": memory_type,
        "project": project_scope,
        "status": "active",
        "created_at": now_iso,
        "superseded": [s["id"] for s in superseded_nodes],
    }

    if as_json:
        print(json.dumps(result_data, indent=2))
        return

    bold = "\033[1m"
    green = "\033[32m"
    cyan = "\033[36m"
    yellow = "\033[33m"
    reset = "\033[0m"

    print(f"\n{bold}{green}✓ Saved architectural memory{reset} [{cyan}{mem_id}{reset}]:")
    print(f"  \"{insight}\"")
    print(f"  Status: {green}active{reset} | Scope: {cyan}{project_scope}{reset} | Tag: {yellow}{tag}{reset} | Type: {memory_type}")

    for s in superseded_nodes:
        print(f"  {yellow}↪ Superseded older memory{reset} [{s['id']}]: \"{s['name']}\"")
    print()


def run_resolve(
    target: str,
    ref: str | None = None,
    note: str | None = None,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Marks an issue or caveat as RESOLVED so agents stop treating it as an active bug.
    """
    if not target or not target.strip():
        print("Error: Target memory ID or keyword is required.", file=sys.stderr)
        sys.exit(1)

    target = target.strip()
    ref = (ref or "manual").strip()
    note = (note or "Resolved and verified").strip()
    now_iso = _get_utc_now()
    resolved_nodes = []

    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        update_query = """
        MATCH (n:Memory)
        WHERE (n.tenant_id = $tenant_id OR n.tenant_id = 'default')
          AND (n.id STARTS WITH $target OR toLower(n.name) CONTAINS toLower($target))
        SET n.status = 'resolved',
            n.resolved_at = $now_iso,
            n.resolved_ref = $ref,
            n.resolved_note = $note
        RETURN n.id as id, n.name as name
        """
        resolved_nodes = neo4j.execute_read(
            update_query,
            {"tenant_id": tenant_id, "target": target, "now_iso": now_iso, "ref": ref, "note": note},
        )
        neo4j.close()
    except Exception as e:
        print(f"Warning: Failed to resolve memory ({e}).", file=sys.stderr)

    if as_json:
        print(json.dumps({"resolved": resolved_nodes, "ref": ref, "note": note}, indent=2))
        return

    bold = "\033[1m"
    green = "\033[32m"
    cyan = "\033[36m"
    reset = "\033[0m"

    if not resolved_nodes:
        print(f"\nNo active memory found matching '{target}'.\n")
        return

    print(f"\n{bold}{green}✓ Marked memory as RESOLVED{reset}:")
    for r in resolved_nodes:
        print(f"  [{cyan}{r['id']}{reset}] \"{r['name']}\"")
        print(f"    Resolution Ref : {ref}")
        print(f"    Resolution Note: {note}")
    print("  This caveat will no longer be treated as an open issue by AI agents.\n")


def run_reopen(
    target: str,
    note: str | None = None,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Reopens a previously resolved memory (Human-in-the-Loop Override).
    If an AI agent falsely marked an issue resolved, the human can reopen it with feedback.
    """
    if not target or not target.strip():
        print("Error: Target memory ID or keyword is required.", file=sys.stderr)
        sys.exit(1)

    target = target.strip()
    note = (note or "Reopened by engineer: still reproducible or incomplete fix").strip()
    now_iso = _get_utc_now()
    reopened_nodes = []

    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        update_query = """
        MATCH (n:Memory)
        WHERE (n.tenant_id = $tenant_id OR n.tenant_id = 'default')
          AND (n.id STARTS WITH $target OR toLower(n.name) CONTAINS toLower($target))
        SET n.status = 'active',
            n.reopened_at = $now_iso,
            n.reopen_note = $note
        RETURN n.id as id, n.name as name
        """
        reopened_nodes = neo4j.execute_read(
            update_query,
            {"tenant_id": tenant_id, "target": target, "now_iso": now_iso, "note": note},
        )
        neo4j.close()
    except Exception as e:
        print(f"Warning: Failed to reopen memory ({e}).", file=sys.stderr)

    if as_json:
        print(json.dumps({"reopened": reopened_nodes, "note": note}, indent=2))
        return

    bold = "\033[1m"
    yellow = "\033[33m"
    cyan = "\033[36m"
    reset = "\033[0m"

    if not reopened_nodes:
        print(f"\nNo memory found matching '{target}'.\n")
        return

    print(f"\n{bold}{yellow}↩ Reopened memory (Marked ACTIVE for AI agents){reset}:")
    for r in reopened_nodes:
        print(f"  [{cyan}{r['id']}{reset}] \"{r['name']}\"")
        print(f"    Reopen Note: {note}")
    print("  This issue is now active again and will be prioritized by AI agents in 'vx context'.\n")


def run_memory_list(
    status_filter: str = "all",
    project: str | None = None,
    all_projects: bool = False,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Lists memories with active, resolved, and superseded statuses.
    """
    nodes = []
    project_scope = None if all_projects else _resolve_project_scope(project)
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        where_clause = "(n.tenant_id = $tenant_id OR n.tenant_id = 'default')"
        if status_filter != "all":
            where_clause += f" AND n.status = '{status_filter}'"
        if not all_projects:
            where_clause += " AND (n.project = $project OR n.project = 'global' OR n.project IS NULL)"

        query = f"""
        MATCH (n:Memory)
        WHERE {where_clause}
        RETURN n.id as id, n.name as name, n.tag as tag, n.type as type, n.status as status,
               n.project as project, n.created_at as created_at, n.resolved_ref as resolved_ref,
               n.resolved_note as resolved_note, n.superseded_by as superseded_by
        ORDER BY n.created_at DESC
        LIMIT 50
        """
        nodes = neo4j.execute_read(query, {"tenant_id": tenant_id, "project": project_scope})
        neo4j.close()
    except Exception:
        pass

    if as_json:
        print(json.dumps(nodes, indent=2))
        return

    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    yellow = "\033[33m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi Architectural Memories                      ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")

    if not nodes:
        print(f"\n  No architectural memories found for project '{project_scope or 'all'}'.")
        print("  Use 'veraxi remember \"<insight>\" --tag <tag>' to record one.\n")
        return

    scope_str = "All Projects" if all_projects else f"Project: {project_scope}"
    print(f"\n  Found {len(nodes)} memory items ({scope_str} | Filter: {status_filter}):")
    print("  " + "─" * 68)

    for n in nodes:
        status = n.get("status", "active")
        if status == "active":
            status_badge = f"{green}[active]{reset}"
        elif status == "resolved":
            status_badge = f"{cyan}[resolved]{reset}"
        else:
            status_badge = f"{yellow}[superseded]{reset}"

        tag = n.get("tag", "general")
        proj_badge = f"\033[2m[{n.get('project', 'general')}]\033[0m "
        print(f"  {status_badge:<18} {cyan}{n['id']}{reset} • {proj_badge}[{tag}] {n['name']}")
        if status == "resolved" and n.get("resolved_ref"):
            print(f"               └─ {green}Resolved ({n['resolved_ref']}){reset}: {n.get('resolved_note', '')}")
        elif status == "superseded" and n.get("superseded_by"):
            print(f"               └─ {yellow}Superseded by {n['superseded_by']}{reset}")

    print()


def run_memory_export(
    output_path: str | None = None,
    project: str | None = None,
    all_projects: bool = False,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Exports project memories into a portable JSON rulebook (.veraxi/rules.json).
    Allows teams to check architectural history into Git for zero-cloud sharing.
    """
    project_scope = None if all_projects else _resolve_project_scope(project)
    nodes = []
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        where_clause = "(n.tenant_id = $tenant_id OR n.tenant_id = 'default')"
        if not all_projects:
            where_clause += " AND (n.project = $project OR n.project = 'global' OR n.project IS NULL)"

        query = f"""
        MATCH (n:Memory)
        WHERE {where_clause}
        RETURN n.id as id, n.name as name, n.tag as tag, n.type as type, n.status as status,
               n.project as project, n.created_at as created_at, n.resolved_ref as resolved_ref,
               n.resolved_note as resolved_note, n.superseded_by as superseded_by
        ORDER BY n.created_at ASC
        """
        nodes = neo4j.execute_read(query, {"tenant_id": tenant_id, "project": project_scope})
        neo4j.close()
    except Exception:
        pass

    export_payload = {
        "version": "1.0",
        "exported_at": _get_utc_now(),
        "project": project_scope or "all",
        "total": len(nodes),
        "memories": nodes,
    }

    if as_json or output_path == "-":
        print(json.dumps(export_payload, indent=2))
        return

    dest = output_path
    if not dest:
        dest_dir = os.path.join(os.getcwd(), ".veraxi")
        os.makedirs(dest_dir, exist_ok=True)
        dest = os.path.join(dest_dir, "rules.json")
    else:
        parent = os.path.dirname(dest)
        if parent:
            os.makedirs(parent, exist_ok=True)

    with open(dest, "w", encoding="utf-8") as f:
        json.dump(export_payload, f, indent=2)

    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    reset = "\033[0m"

    print(f"\n{bold}{green}✓ Successfully exported {len(nodes)} memory item(s){reset} to:")
    print(f"  {cyan}{dest}{reset}")
    print("  You can commit this file to Git to share architectural memory with your team.\n")


def run_memory_import(
    file_path: str | None = None,
    project: str | None = None,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Imports a JSON rulebook (.veraxi/rules.json) into the local or cloud knowledge graph.
    """
    src_file = file_path or os.path.join(os.getcwd(), ".veraxi", "rules.json")
    if not os.path.isfile(src_file):
        print(f"Error: memory file not found at '{src_file}'.", file=sys.stderr)
        sys.exit(1)

    with open(src_file, "r", encoding="utf-8") as f:
        data = json.load(f)

    memories = data.get("memories", [])
    if not memories:
        print(f"Warning: no memories found in '{src_file}'.", file=sys.stderr)
        return

    imported_count = 0
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        for m in memories:
            props = {
                "id": m.get("id") or str(uuid.uuid4())[:8],
                "name": m.get("name", ""),
                "tag": m.get("tag", "rule"),
                "type": m.get("type", "rule"),
                "status": m.get("status", "active"),
                "project": m.get("project") or _resolve_project_scope(project),
                "created_at": m.get("created_at") or _get_utc_now(),
                "resolved_ref": m.get("resolved_ref"),
                "resolved_note": m.get("resolved_note"),
                "superseded_by": m.get("superseded_by"),
                "tenant_id": tenant_id,
            }
            neo4j.execute_write(
                """
                MERGE (n:Memory {id: $props.id, tenant_id: $props.tenant_id})
                SET n += $props
                """,
                {"props": props},
            )
            imported_count += 1
        neo4j.close()
    except Exception:
        pass

    if as_json:
        print(json.dumps({"imported": imported_count, "file": src_file}, indent=2))
        return

    bold = "\033[1m"
    green = "\033[32m"
    cyan = "\033[36m"
    reset = "\033[0m"

    print(f"\n{bold}{green}✓ Successfully imported {imported_count} memory item(s){reset} from:")
    print(f"  {cyan}{src_file}{reset}")
    print("  Imported rules are now active and accessible across 'vx context' and 'vx rules sync'.\n")


def run_memory_audit(
    project: str | None = None,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Audits the project memory bank for stale constraints, contradictions, and tag crowding.
    """
    project_scope = _resolve_project_scope(project)
    nodes = []
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        query = """
        MATCH (n:Memory)
        WHERE (n.tenant_id = $tenant_id OR n.tenant_id = 'default')
          AND (n.project = $project OR n.project = 'global' OR n.project IS NULL)
        RETURN n.id as id, n.name as name, n.tag as tag, n.type as type, n.status as status,
               n.project as project, n.created_at as created_at, n.resolved_ref as resolved_ref,
               n.resolved_note as resolved_note, n.superseded_by as superseded_by
        ORDER BY n.created_at DESC
        """
        nodes = neo4j.execute_read(query, {"tenant_id": tenant_id, "project": project_scope})
        neo4j.close()
    except Exception:
        pass

    # Offline fallback
    if not nodes:
        local_file = os.path.join(os.getcwd(), ".veraxi", "rules.json")
        if os.path.isfile(local_file):
            try:
                with open(local_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    nodes = data.get("memories", [])
            except Exception:
                pass

    active = [n for n in nodes if n.get("status") == "active"]
    resolved = [n for n in nodes if n.get("status") == "resolved"]
    superseded = [n for n in nodes if n.get("status") == "superseded"]

    by_tag = {}
    for a in active:
        t = a.get("tag", "general")
        by_tag.setdefault(t, []).append(a)

    overlapping_tags = {t: items for t, items in by_tag.items() if len(items) > 2}

    health_score = 100
    if len(overlapping_tags) > 0:
        health_score -= len(overlapping_tags) * 5
    if len(active) > 15:
        health_score -= 10
    health_score = max(50, min(100, health_score))

    report = {
        "project": project_scope,
        "health_score": health_score,
        "total": len(nodes),
        "active_count": len(active),
        "resolved_count": len(resolved),
        "superseded_count": len(superseded),
        "crowded_tags": list(overlapping_tags.keys()),
    }

    if as_json:
        print(json.dumps(report, indent=2))
        return

    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    yellow = "\033[33m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi Architectural Memory Health Audit           ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")

    score_color = green if health_score >= 85 else yellow
    print(f"\n  Project Scope: {bold}{project_scope}{reset}")
    print(f"  Health Score: {score_color}{bold}{health_score}/100{reset} ({'HEALTHY' if health_score >= 85 else 'NEEDS REVIEW'})")

    print("\n  Memory Lifecycle Breakdown:")
    print(f"  • {green}[active]{reset}: {len(active)} rules currently guiding AI agents")
    print(f"  • {cyan}[resolved]{reset}: {len(resolved)} past issues marked solved (guarded against re-solving)")
    print(f"  • {yellow}[superseded]{reset}: {len(superseded)} historical rules replaced by newer architecture")

    if overlapping_tags:
        print(f"\n  {yellow}Attention Areas:{reset}")
        for t, items in overlapping_tags.items():
            print(f"  • Tag '[{t}]' has {len(items)} active rules. Consider consolidating with 'vx remember --supersedes'.")
    else:
        print(f"\n  {green}✓ No conflicting or crowded memory tags detected.{reset}")

    print("\n  Tip: Run 'vx rules sync' to propagate active rules directly to your editor.\n")

