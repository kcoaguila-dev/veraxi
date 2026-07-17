from typing import Dict, Any
from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient

def update_entity(entity_name: str, properties: Dict[str, Any], tenant_id: str = "default") -> str:
    """
    Updates the properties of an existing entity in Neo4j.
    """
    config = get_config()
    neo4j = Neo4jStorageClient(
        uri=config.neo4j_uri, user=config.neo4j_user, password=config.neo4j_password
    )

    query = """
    MATCH (n {name: $entity_name, tenant_id: $tenant_id})
    SET n += $properties
    RETURN count(n) AS updated_count
    """

    try:
        results = neo4j.execute_read(
            query, 
            {"entity_name": entity_name, "tenant_id": tenant_id, "properties": properties}
        )
        count = results[0]["updated_count"] if results else 0
        return f"Successfully updated properties for {count} entity(s) matching '{entity_name}'."
    finally:
        neo4j.close()
