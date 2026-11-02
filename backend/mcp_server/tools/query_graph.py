import logging

from backend.config import get_config
from backend.retrieval.merge_rank import GraphHit
from backend.storage.neo4j_client import Neo4jStorageClient

logger = logging.getLogger(__name__)


def query_graph(
    entity_name: str, max_hops: int = 2, tenant_id: str = "default"
) -> list[GraphHit]:
    """
    Perform a parameterized Cypher traversal from a starting entity out to max_hops.
    Returns results as GraphHit objects ready for merge_rank.
    No string-concatenated queries for user inputs.
    """
    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)

    # max_hops is an integer and controlled/validated by us (or typed as int from MCP tool).
    # We must ensure it's a positive integer to avoid injection.
    max_hops = max(1, int(max_hops))

    # We parameterize the entity_name and tenant_id
    query = f"""
    MATCH (start)
    WHERE (start.name = $entity_name 
           OR toLower(start.name) = toLower($entity_name) 
           OR toLower(start.name) CONTAINS toLower($entity_name)
           OR (size(start.name) > 4 AND toLower($entity_name) CONTAINS toLower(start.name))
           OR any(a in coalesce(start.aliases, []) WHERE toLower(a) = toLower($entity_name) OR toLower(a) CONTAINS toLower($entity_name)))
      AND start.tenant_id = $tenant_id
    WITH start LIMIT 5
    MATCH (start)-[rels*1..{max_hops}]-(end)
    WHERE end.qdrant_point_ids IS NOT NULL
      AND end.tenant_id = $tenant_id
    WITH DISTINCT end, last(rels) AS last_rel LIMIT 50
    UNWIND end.qdrant_point_ids AS qid
    RETURN DISTINCT end.id AS id,
           qid AS qdrant_point_id,
           labels(end) AS labels,
           properties(end) AS props,
           type(last_rel) AS relation_type,
           last_rel.last_confirmed_at AS last_confirmed_at,
           last_rel.source AS relation_source
    LIMIT 100
    """

    # Execute query
    results = neo4j.execute_read(
        query, {"entity_name": entity_name, "tenant_id": tenant_id}
    )
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
            payload = row.get("props", {}).copy()
            payload["labels"] = row.get("labels", [])
            if row.get("relation_type"):
                payload["relation_type"] = row.get("relation_type")
            if row.get("last_confirmed_at"):
                payload["last_confirmed_at"] = row.get("last_confirmed_at")
            if row.get("relation_source"):
                payload["relation_source"] = row.get("relation_source")
            hits.append(GraphHit(id=q_id, payload=payload))

    # Hydrate GraphHits with document chunk text, page_number, and source from Qdrant
    if hits:
        try:
            from backend.storage.qdrant_client import QdrantStorageClient

            qdrant = QdrantStorageClient.from_config(config)
            q_ids = [h.id for h in hits]
            q_points = qdrant.get_points(config.qdrant_collection_name, q_ids)
            q_map = {
                p["id"]: p.get("payload", {})
                for p in q_points
                if isinstance(p, dict) and "id" in p
            }
            for h in hits:
                if h.id in q_map:
                    for k, v in q_map[h.id].items():
                        if k not in h.payload or not h.payload[k]:
                            h.payload[k] = v
        except Exception as exc:
            logger.debug(f"Failed to hydrate graph hits from Qdrant payloads: {exc}")

    return hits
