import json
import sys


def run_query(
    query: str,
    as_json: bool = False,
    tenant_id: str = "default",
    limit: int = 10,
    endpoint: str = "https://api.veraxi.me/sse",
    key: str | None = None,
):
    """
    Executes a query using Just-In-Time retrieval logic.
    Attempts local direct execution if running on a Veraxi backend host,
    or falls back to endpoint verification / remote query.
    """
    result = None

    # Try local backend execution first if in a server environment
    try:
        from backend.retrieval.just_in_time_graph import build_lazy_graph_dossier
        result = build_lazy_graph_dossier(query, tenant_id=tenant_id, limit=limit)
    except ImportError:
        pass

    if result is None:
        # Remote execution over MCP / SSE or API endpoint
        # The user is querying a remote server from their laptop
        import urllib.request
        import urllib.error

        # Query via Veraxi API if available or diagnostic feedback
        req = urllib.request.Request(endpoint)
        if key:
            req.add_header("Authorization", f"Bearer {key}")

        try:
            # Check endpoint reachability
            with urllib.request.urlopen(req, timeout=5) as response:
                status = response.getcode()
            result = {
                "query": query,
                "tenant_id": tenant_id,
                "remote_endpoint": endpoint,
                "status": f"Connected ({status} OK)",
                "note": "Connected to Veraxi MCP server over SSE. Queries can be invoked directly by AI agents (Claude, Cursor, Cline) via configured MCP tools."
            }
        except urllib.error.HTTPError as e:
            if e.code == 401:
                print("Error: 401 Unauthorized - Please provide a valid Veraxi API key with --key or VERAXI_API_KEY.", file=sys.stderr)
                sys.exit(1)
            else:
                print(f"Error connecting to {endpoint}: {e.code} {e.reason}", file=sys.stderr)
                sys.exit(1)
        except Exception as e:
            print(f"Error connecting to {endpoint}: {e}", file=sys.stderr)
            sys.exit(1)

    if as_json:
        print(json.dumps(result, indent=2))
        return

    print(f"Results for query: '{query}'")
    print("=" * 60)

    chunks = result.get("chunks", [])
    if chunks:
        print(f"Retrieved {len(chunks)} chunks.")
        for i, chunk in enumerate(chunks, 1):
            print(f"\n--- Result {i} ---")
            print(f"Score: {chunk.get('score', 0.0):.4f}")
            print(f"Source: {chunk.get('title', 'Unknown')}")

            entities = chunk.get("linked_entities", [])
            if entities:
                print("Linked Entities:")
                for e in entities:
                    print(f"  - {e.get('name')} ({e.get('type')})")

            text = chunk.get("text", "")
            if len(text) > 300:
                print(f"\nExcerpt:\n{text[:300]}...")
            else:
                print(f"\nExcerpt:\n{text}")
    elif "status" in result:
        print(f"Status: {result.get('status')}")
        print(f"Endpoint: {result.get('remote_endpoint')}")
        print(f"Note: {result.get('note')}")
