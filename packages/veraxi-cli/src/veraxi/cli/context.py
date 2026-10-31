import json
import sys
from veraxi.cli.cluster import get_cluster_repos
from veraxi.cli.utils import resolve_project_scope as _resolve_project_scope


def run_context(
    task: str | None = None,
    project: str | None = None,
    tenant_id: str = "default",
    limit: int = 4,
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Assembles a token-efficient, hallucination-resistant XML/Markdown context pack
    scoped to the current project codebase and its cluster microservices, containing
    active architectural rules, relevant grounding evidence, and resolved caveats.
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

    project_scope = _resolve_project_scope(project)
    cluster_scopes = get_cluster_repos(project_scope, tenant_id)
    if not cluster_scopes:
        cluster_scopes = [project_scope]

    active_rules = []
    resolved_caveats = []
    vector_chunks = []

    # 1. Fetch active rules and resolved caveats from graph scoped to project cluster or global
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
              AND (n.project IN $cluster_scopes OR n.project = 'global' OR n.project IS NULL)
              AND n.status = 'active'
            RETURN n.id as id, n.name as name, n.tag as tag, n.type as type, n.project as project
            ORDER BY n.created_at DESC
            LIMIT 10
            """,
            {"tenant_id": tenant_id, "cluster_scopes": cluster_scopes},
        )
        active_rules = rule_rows

        # Resolved caveats (preventing zombie bug fixing)
        caveat_rows = neo4j.execute_read(
            """
            MATCH (n:Memory)
            WHERE (n.tenant_id = $tenant_id OR n.tenant_id = 'default')
              AND (n.project IN $cluster_scopes OR n.project = 'global' OR n.project IS NULL)
              AND n.status = 'resolved'
            RETURN n.id as id, n.name as name, n.tag as tag, n.project as project, n.resolved_ref as ref, n.resolved_note as note
            ORDER BY n.resolved_at DESC
            LIMIT 5
            """,
            {"tenant_id": tenant_id, "cluster_scopes": cluster_scopes},
        )
        resolved_caveats = caveat_rows
        neo4j.close()
    except Exception:
        pass

    # 1b. Offline fallback: check local .veraxi/rules.json if active_rules is empty
    if not active_rules:
        import os

        local_file = os.path.join(os.getcwd(), ".veraxi", "rules.json")
        if os.path.isfile(local_file):
            try:
                with open(local_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    for item in data.get("memories", []):
                        proj = item.get("project")
                        if proj in cluster_scopes or proj == "global" or not proj:
                            if item.get("status") == "active":
                                active_rules.append(item)
                            elif item.get("status") == "resolved":
                                resolved_caveats.append(item)
            except Exception:
                pass

    # 2. Fetch relevant vector chunks
    try:
        from backend.mcp_server.tools.search_vectors import search_vectors

        hits = search_vectors(query_text=task[:400], limit=limit, tenant_id=tenant_id)
        for h in hits:
            if isinstance(h, dict) and "text" in h:
                vector_chunks.append(
                    {
                        "text": h["text"].strip(),
                        "score": h.get("score", 0.0),
                        "source": h.get("source", "knowledge_base"),
                    }
                )
    except Exception:
        pass

    if as_json:
        result = {
            "task": task,
            "project": project_scope,
            "cluster": cluster_scopes,
            "tenant_id": tenant_id,
            "active_rules": active_rules,
            "resolved_caveats": resolved_caveats,
            "evidence": vector_chunks,
        }
        print(json.dumps(result, indent=2))
        return

    # Render clean XML context block for AI coding agents
    output = []
    cluster_attr = (
        f' cluster="{",".join(cluster_scopes)}"' if len(cluster_scopes) > 1 else ""
    )
    output.append(
        f'<veraxi-context version="1.0" project="{project_scope}"{cluster_attr} tenant="{tenant_id}">'
    )
    output.append(f"  <task>\n    {task}\n  </task>\n")

    if active_rules:
        output.append("  <!-- ACTIVE ARCHITECTURAL RULES & CONSTRAINTS -->")
        output.append("  <active-rules>")
        for r in active_rules:
            tag = r.get("tag", "general")
            proj_prefix = (
                f"[{r['project']}] "
                if r.get("project")
                and r["project"] != project_scope
                and r["project"] != "global"
                else ""
            )
            output.append(f"    - {proj_prefix}[{tag}] {r['name']}")
        output.append("  </active-rules>\n")

    if resolved_caveats:
        output.append(
            "  <!-- HISTORICAL RESOLVED ISSUES (DO NOT RE-SOLVE OR RE-INTRODUCE) -->"
        )
        output.append('  <resolved-caveats status="DO-NOT-RE-SOLVE">')
        for c in resolved_caveats:
            ref = c.get("ref", "manual")
            note = c.get("note", "Fixed")
            proj_prefix = (
                f"[{c['project']}] "
                if c.get("project")
                and c["project"] != project_scope
                and c["project"] != "global"
                else ""
            )
            output.append(f"    - {proj_prefix}[RESOLVED via {ref}]: {c['name']}")
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
