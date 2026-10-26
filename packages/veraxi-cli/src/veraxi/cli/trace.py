import json
import sys


def run_trace(
    entity: str,
    hops: int = 2,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Traces and visualizes multi-hop causal and dependency paths starting from an entity.
    """
    if not entity or not entity.strip():
        print("Error: entity name is required for trace.", file=sys.stderr)
        sys.exit(1)

    entity = entity.strip()
    hops = min(max(1, hops), 4)
    paths_data = []

    # Try local backend inspection
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        query = f"""
        MATCH (start)
        WHERE toLower(start.name) CONTAINS toLower($entity)
        MATCH path = (start)-[r*1..{hops}]-(target)
        RETURN [n in nodes(path) | n.name] as nodes, [rel in relationships(path) | type(rel)] as rels
        LIMIT 25
        """
        rows = neo4j.execute_read(query, {"entity": entity})
        neo4j.close()
        for r in rows:
            paths_data.append({"nodes": r.get("nodes", []), "rels": r.get("rels", [])})
    except Exception:
        pass

    if as_json:
        print(json.dumps(paths_data, indent=2))
        return

    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    yellow = "\033[33m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi Knowledge Graph Trace                       ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")

    if not paths_data:
        print(f"\n  No graph relationships found matching entity: '{entity}'.\n")
        return

    print(f"\n  {bold}Entity Knowledge Trace:{reset} {cyan}{entity}{reset} (Depth: {hops} hops, {len(paths_data)} paths found)")
    print("  " + "─" * 60)

    seen_paths = set()
    for row in paths_data:
        nodes = row.get("nodes", [])
        rels = row.get("rels", [])
        if not nodes or not rels:
            continue

        path_sig = "->".join(nodes) + ":" + "->".join(rels)
        if path_sig in seen_paths:
            continue
        seen_paths.add(path_sig)

        chain_parts = [f"{bold}{nodes[0]}{reset}"]
        for i in range(len(rels)):
            chain_parts.append(f"──[{yellow}{rels[i]}{reset}]──▶ {green}{nodes[i+1]}{reset}")
        print("  " + " ".join(chain_parts))

    print()
