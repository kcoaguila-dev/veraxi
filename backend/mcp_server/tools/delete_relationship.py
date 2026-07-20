from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient

def delete_relationship(from_entity: str, to_entity: str, rel_type: str, tenant_id: str = "default") -> str:
    """
    Deletes a specific relationship between two entities in Neo4j without deleting the entities themselves.
    """
    if not rel_type.replace("_", "").isalnum():
        raise ValueError("Relationship type must be alphanumeric/underscores")

    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)

    query = f"""
    MATCH (a {{name: $from_entity, tenant_id: $tenant_id}})-[r:{rel_type}]->(b {{name: $to_entity, tenant_id: $tenant_id}})
    DELETE r
    RETURN count(r) AS deleted_count
    """

    try:
        results = neo4j.execute_read(
            query, 
            {"from_entity": from_entity, "to_entity": to_entity, "tenant_id": tenant_id}
        )
        count = results[0]["deleted_count"] if results else 0
        return f"Successfully deleted {count} '{rel_type}' relationship(s) between '{from_entity}' and '{to_entity}'."
    finally:
        neo4j.close()
