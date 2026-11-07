from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient


def get_graph_schema(tenant_id: str = "default") -> dict[str, list[str]]:
    """
    Retrieves unique Node Labels and Relationship Types present for the given tenant in Neo4j.
    Prevents cross-tenant schema leakage in multi-tenant environments.
    """
    config = get_config()
    neo4j_client = Neo4jStorageClient.from_config(config)

    try:
        # Get node labels for this tenant
        labels_query = """
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
        UNWIND labels(n) AS lbl
        RETURN DISTINCT lbl AS label
        """
        labels_result = neo4j_client.execute_read(labels_query, {"tenant_id": tenant_id})
        labels = [row["label"] for row in labels_result if row.get("label")]

        # Get relationship types for this tenant
        rels_query = """
        MATCH (a)-[r]->(b)
        WHERE (r.tenant_id = $tenant_id) OR (a.tenant_id = $tenant_id AND b.tenant_id = $tenant_id)
        RETURN DISTINCT type(r) AS rel_type
        """
        rels_result = neo4j_client.execute_read(rels_query, {"tenant_id": tenant_id})
        relationship_types = [row["rel_type"] for row in rels_result if row.get("rel_type")]

        return {
            "node_labels": sorted(set(labels)),
            "relationship_types": sorted(set(relationship_types)),
        }
    finally:
        neo4j_client.close()
