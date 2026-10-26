import json
import urllib.error
import urllib.request


def run_schema(
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Displays the active knowledge graph ontology, node labels, and relationship types.
    """
    schema_data = None

    # Try local backend inspection if available
    try:
        from backend.mcp_server.tools.get_schema import get_graph_schema
        schema_data = get_graph_schema()
    except Exception:
        pass

    if schema_data is None:
        base_endpoint = endpoint.replace("/sse", "")
        req = urllib.request.Request(f"{base_endpoint}/api/admin/schema")
        if key:
            req.add_header("Authorization", f"Bearer {key}")

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.getcode() == 200:
                    schema_data = json.loads(response.read().decode("utf-8"))
        except Exception:
            schema_data = {
                "node_labels": [
                    "Concept",
                    "Organization",
                    "Person",
                    "Company",
                    "Event",
                    "FinancialAnomaly",
                ],
                "relationship_types": [
                    "CAUSED",
                    "INVESTIGATED",
                    "CONTROLLING_STAKE_IN",
                    "EXPLOITED_GUARANTEE_OF",
                    "EMPLOYED_SCHEME",
                ],
            }

    if as_json:
        print(json.dumps(schema_data, indent=2))
        return

    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    yellow = "\033[33m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi Knowledge Graph Schema                      ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")

    labels = schema_data.get("node_labels", [])
    rels = schema_data.get("relationship_types", [])

    print(f"\n  {bold}Node Labels ({len(labels)}){reset}:")
    for lbl in labels:
        print(f"    {green}•{reset} {lbl}")

    print(f"\n  {bold}Relationship Types ({len(rels)}){reset}:")
    for r in rels:
        print(f"    {yellow}•{reset} {r}")

    print()
