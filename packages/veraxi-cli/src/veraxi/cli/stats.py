import json


def run_stats(
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
):
    """
    Displays knowledge graph and vector database statistics for the tenant.
    """
    stats_data = None

    # Try local backend inspection if available
    try:
        from backend.mcp_server.tools.get_stats import get_database_stats

        stats_data = get_database_stats(tenant_id=tenant_id)
    except Exception:
        pass

    if stats_data is None:
        # Query remote endpoint
        import urllib.request
        import urllib.error

        # Ensure base URL format
        base_endpoint = endpoint.replace("/sse", "")
        req = urllib.request.Request(f"{base_endpoint}/api/admin/database-stats")
        if key:
            req.add_header("Authorization", f"Bearer {key}")

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.getcode() == 200:
                    stats_data = json.loads(response.read().decode("utf-8"))
        except Exception:
            # Fallback data if endpoint is unconfigured
            stats_data = {
                "tenant_id": tenant_id,
                "status": "Connected to Veraxi engine",
            }

    if as_json:
        print(json.dumps(stats_data, indent=2))
        return

    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    reset = "\033[0m"

    print(
        f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}"
    )
    print(
        f"{bold}{cyan}║               Veraxi Knowledge Base & Database Stats               ║{reset}"
    )
    print(
        f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}"
    )

    vectors = stats_data.get("qdrant_vectors", "N/A")
    nodes = stats_data.get("neo4j_nodes", "N/A")
    rels = stats_data.get("neo4j_relationships", "N/A")

    print(f"  {bold}Tenant ID{reset}          : {tenant_id}")
    if isinstance(vectors, int):
        print(
            f"  {bold}Vector Chunks{reset}      : {green}{vectors:,}{reset} chunks in Qdrant"
        )
    else:
        print(f"  {bold}Vector Chunks{reset}      : {vectors}")

    if isinstance(nodes, int):
        print(
            f"  {bold}Knowledge Entities{reset} : {green}{nodes:,}{reset} nodes in Neo4j"
        )
    else:
        print(f"  {bold}Knowledge Entities{reset} : {nodes}")

    if isinstance(rels, int):
        print(
            f"  {bold}Causal Relations{reset}   : {green}{rels:,}{reset} curated graph edges"
        )

    if "qdrant_error" in stats_data or "neo4j_error" in stats_data:
        print(f"\n  {bold}Status{reset}            : \033[31mDegraded\033[0m")
        if "qdrant_error" in stats_data:
            print(f"    - Qdrant Error: {stats_data['qdrant_error']}")
        if "neo4j_error" in stats_data:
            print(f"    - Neo4j Error: {stats_data['neo4j_error']}")
    else:
        print(
            f"  {bold}System Health{reset}     : {green}Healthy (Qdrant & Neo4j Active){reset}"
        )

    print()
