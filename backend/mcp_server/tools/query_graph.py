from typing import List
from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.retrieval.merge_rank import GraphHit

def query_graph(entity_name: str, max_hops: int = 2) -> List[GraphHit]:
    """
    Perform a parameterized Cypher traversal from a starting entity out to max_hops.
    Returns results as GraphHit objects ready for merge_rank.
    No string-concatenated queries for user inputs.
    """
    config = get_config()
    neo4j = Neo4jStorageClient(uri=config.neo4j_uri, user=config.neo4j_user, password=config.neo4j_password)

    # max_hops is an integer and controlled/validated by us (or typed as int from MCP tool).
    # We must ensure it's a positive integer to avoid injection.
    max_hops = max(1, int(max_hops))

    # We parameterize the entity_name
    query = f"""
    MATCH (start {{name: $entity_name}})-[*1..{max_hops}]-(end)
    WHERE end.qdrant_point_id IS NOT NULL
    RETURN DISTINCT end.id AS id, end.qdrant_point_id AS qdrant_point_id, labels(end) AS labels, properties(end) AS props
    """

    # Execute query
    results = neo4j.execute_read(query, {"entity_name": entity_name})
    neo4j.close()

    # Return as GraphHit objects
    hits = []
    # Deduplicate node IDs explicitly just in case
    seen = set()
    for row in results:
        # qdrant_point_id is required to be considered the ID by merge_rank, as it expects matching IDs
        # The prompt says: "Every Neo4j node written during ingestion must store its corresponding Qdrant point ID... Breaking this link is a critical bug."
        # Since merge_rank uses IDs to merge, and we merge vector and graph, the shared ID is the qdrant_point_id.
        q_id = row.get("qdrant_point_id")
        if q_id and q_id not in seen:
            seen.add(q_id)
            payload = row.get("props", {})
            payload["labels"] = row.get("labels", [])
            hits.append(GraphHit(
                id=q_id,
                payload=payload
            ))

    return hits
