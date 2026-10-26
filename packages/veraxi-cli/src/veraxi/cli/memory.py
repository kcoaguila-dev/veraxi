import datetime
import json
import sys
import uuid


def _get_utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def run_remember(
    insight: str,
    tag: str | None = None,
    memory_type: str = "rule",
    supersedes: str | None = None,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Stores an architectural rule, decision, or known constraint into the knowledge graph.
    Prevents memory pollution by explicitly marking superseded older memories.
    """
    if not insight or not insight.strip():
        print("Error: insight text is required.", file=sys.stderr)
        sys.exit(1)

    insight = insight.strip()
    tag = (tag or "general").strip().lower()
    memory_type = (memory_type or "rule").strip().lower()
    now_iso = _get_utc_now()
    mem_id = str(uuid.uuid4())[:8]

    superseded_nodes = []

    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        # Handle superseding
        if supersedes:
            find_query = """
            MATCH (old:Memory)
            WHERE (old.tenant_id = $tenant_id OR old.tenant_id = 'default')
              AND old.status = 'active'
              AND (toLower(old.name) CONTAINS toLower($supersedes) OR old.id STARTS WITH $supersedes)
            SET old.status = 'superseded', old.superseded_by = $new_id, old.superseded_at = $now_iso
            RETURN old.id as id, old.name as name
            """
            superseded_nodes = neo4j.execute_read(
                find_query,
                {"tenant_id": tenant_id, "supersedes": supersedes, "new_id": mem_id, "now_iso": now_iso},
            )

        create_query = """
        CREATE (n:Memory {
            id: $id,
            name: $name,
            details: $name,
            tag: $tag,
            type: $type,
            status: 'active',
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
    print(f"  Status: {green}active{reset} | Tag: {yellow}{tag}{reset} | Type: {memory_type}")

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


def run_memory_list(
    status_filter: str = "all",
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Lists memories with active, resolved, and superseded statuses.
    """
    nodes = []
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        where_clause = "(n.tenant_id = $tenant_id OR n.tenant_id = 'default')"
        if status_filter != "all":
            where_clause += f" AND n.status = '{status_filter}'"

        query = f"""
        MATCH (n:Memory)
        WHERE {where_clause}
        RETURN n.id as id, n.name as name, n.tag as tag, n.type as type, n.status as status,
               n.created_at as created_at, n.resolved_ref as resolved_ref, n.resolved_note as resolved_note,
               n.superseded_by as superseded_by
        ORDER BY n.created_at DESC
        LIMIT 50
        """
        nodes = neo4j.execute_read(query, {"tenant_id": tenant_id})
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
        print("\n  No architectural memories recorded yet.")
        print("  Use 'veraxi remember \"<insight>\" --tag <tag>' to record one.\n")
        return

    print(f"\n  Found {len(nodes)} memory items (Filter: {status_filter}):")
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
        print(f"  {status_badge:<18} {cyan}{n['id']}{reset} • [{tag}] {n['name']}")
        if status == "resolved" and n.get("resolved_ref"):
            print(f"               └─ {green}Resolved ({n['resolved_ref']}){reset}: {n.get('resolved_note', '')}")
        elif status == "superseded" and n.get("superseded_by"):
            print(f"               └─ {yellow}Superseded by {n['superseded_by']}{reset}")

    print()
