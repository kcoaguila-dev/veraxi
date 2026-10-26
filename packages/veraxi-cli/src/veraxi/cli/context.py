import json
import sys


def run_context(
    task: str | None = None,
    tenant_id: str = "default",
    limit: int = 4,
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Assembles a token-efficient, hallucination-resistant XML/Markdown context pack
    containing active architectural rules, relevant grounding evidence, and
    resolved caveats (explicitly marked DO-NOT-RE-SOLVE to prevent regressions).
    """
    if not task:
        if not sys.stdin.isatty():
            task = sys.stdin.read().strip()
        else:
            print("Error: task description is required.", file=sys.stderr)
            sys.exit(1)

    if not task:
        print("Error: task description is required.", file=sys.stderr)
        sys.exit(1)

    active_rules = []
    resolved_caveats = []
    vector_chunks = []

    # 1. Fetch active rules and resolved caveats from graph
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        # Active rules
        rule_rows = neo4j.execute_read(
            """
            MATCH (n:Memory)
            WHERE (n.tenant_id = $tenant_id OR n.tenant_id = 'default')
              AND n.status = 'active'
            RETURN n.id as id, n.name as name, n.tag as tag, n.type as type
            ORDER BY n.created_at DESC
            LIMIT 10
            """,
            {"tenant_id": tenant_id},
        )
        active_rules = rule_rows

        # Resolved caveats (preventing zombie bug fixing)
        caveat_rows = neo4j.execute_read(
            """
            MATCH (n:Memory)
            WHERE (n.tenant_id = $tenant_id OR n.tenant_id = 'default')
              AND n.status = 'resolved'
            RETURN n.id as id, n.name as name, n.tag as tag, n.resolved_ref as ref, n.resolved_note as note
            ORDER BY n.resolved_at DESC
            LIMIT 5
            """,
            {"tenant_id": tenant_id},
        )
        resolved_caveats = caveat_rows
        neo4j.close()
    except Exception:
        pass

    # 2. Fetch relevant vector chunks
    try:
        from backend.mcp_server.tools.search_vectors import search_vectors

        hits = search_vectors(query_text=task[:400], limit=limit, tenant_id=tenant_id)
        for h in hits:
            if isinstance(h, dict) and "text" in h:
                vector_chunks.append({
                    "text": h["text"].strip(),
                    "score": h.get("score", 0.0),
                    "source": h.get("source", "knowledge_base"),
                })
    except Exception:
        pass

    if as_json:
        result = {
            "task": task,
            "tenant_id": tenant_id,
            "active_rules": active_rules,
            "resolved_caveats": resolved_caveats,
            "evidence": vector_chunks,
        }
        print(json.dumps(result, indent=2))
        return

    # Render clean XML context block for AI coding agents
    output = []
    output.append(f'<veraxi-context version="1.0" tenant="{tenant_id}">')
    output.append(f"  <task>\n    {task}\n  </task>\n")

    if active_rules:
        output.append("  <!-- ACTIVE ARCHITECTURAL RULES & CONSTRAINTS -->")
        output.append("  <active-rules>")
        for r in active_rules:
            tag = r.get("tag", "general")
            output.append(f"    - [{tag}] {r['name']}")
        output.append("  </active-rules>\n")

    if resolved_caveats:
        output.append("  <!-- HISTORICAL RESOLVED ISSUES (DO NOT RE-SOLVE OR RE-INTRODUCE) -->")
        output.append('  <resolved-caveats status="DO-NOT-RE-SOLVE">')
        for c in resolved_caveats:
            ref = c.get("ref", "manual")
            note = c.get("note", "Fixed")
            output.append(f"    - [RESOLVED via {ref}]: {c['name']}")
            output.append(f"      Resolution Note: {note}")
        output.append("  </resolved-caveats>\n")

    if vector_chunks:
        output.append("  <!-- VERIFIED GROUNDING EVIDENCE -->")
        output.append("  <grounding-evidence>")
        for idx, chunk in enumerate(vector_chunks, 1):
            output.append(f"    [Evidence #{idx} | Source: {chunk['source']}]")
            output.append(f"    {chunk['text']}\n")
        output.append("  </grounding-evidence>")

    output.append("</veraxi-context>")

    print("\n".join(output))
