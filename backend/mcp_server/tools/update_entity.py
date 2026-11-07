from typing import Any

from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient


RESERVED_ENTITY_PROPS = {
    "id",
    "tenant_id",
    "entity_key",
    "acronym_key",
    "qdrant_point_ids",
}


def update_entity(
    entity_name: str, properties: dict[str, Any], tenant_id: str = "default"
) -> str:
    """
    Updates the properties of an existing entity in Neo4j, protecting internal link keys.
    """
    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)

    safe_props = {
        k: v
        for k, v in (properties or {}).items()
        if k not in RESERVED_ENTITY_PROPS
    }

    query = """
    MATCH (n {tenant_id: $tenant_id})
    WHERE toLower(n.name) = toLower($entity_name)
       OR any(a IN coalesce(n.aliases, []) WHERE toLower(a) = toLower($entity_name))
    SET n += $properties
    RETURN count(n) AS updated_count
    """

    try:
        params = {
            "entity_name": entity_name,
            "tenant_id": tenant_id,
            "properties": safe_props,
        }
        results = neo4j.execute_write(query, params)
        count = results[0]["updated_count"] if results else 0
        return f"Successfully updated properties for {count} entity(s) matching '{entity_name}'."
    finally:
        neo4j.close()
