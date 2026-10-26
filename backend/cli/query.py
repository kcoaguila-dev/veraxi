import json
import sys
from backend.retrieval.just_in_time_graph import build_lazy_graph_dossier

def run_query(query: str, as_json: bool = False, tenant_id: str = "default"):
    """
    Executes a query using Just-In-Time retrieval logic directly against the local backend,
    avoiding an HTTP request since the backend code is accessible.
    """
    try:
        # Calls the function discovered in backend/retrieval/just_in_time_graph.py
        result = build_lazy_graph_dossier(query, tenant_id=tenant_id)

        if as_json:
            print(json.dumps(result, indent=2))
            return

        print(f"Results for query: '{query}'")
        print("=" * 60)

        chunks = result.get("chunks", [])
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
            # Truncate text for display if it's very long
            if len(text) > 300:
                print(f"\nExcerpt:\n{text[:300]}...")
            else:
                print(f"\nExcerpt:\n{text}")

    except Exception as e:
        print(f"Error executing query: {e}", file=sys.stderr)
        sys.exit(1)
