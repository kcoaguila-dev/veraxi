from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient

def delete_entity(entity_name: str, tenant_id: str = "default") -> str:
    """
    Deletes an entity (node) and all its connected relationships from Neo4j.
    """
    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)

    query = """
    MATCH (n {name: $entity_name, tenant_id: $tenant_id})
    DETACH DELETE n
    RETURN count(n) AS deleted_count
    """

    try:
        results = neo4j.execute_read(query, {"entity_name": entity_name, "tenant_id": tenant_id})
        count = results[0]["deleted_count"] if results else 0
        return f"Successfully deleted {count} entity(s) matching '{entity_name}'."
    finally:
        neo4j.close()
