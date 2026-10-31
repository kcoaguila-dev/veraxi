import logging
from typing import Any

from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient

logger = logging.getLogger(__name__)


def insert_graph_nodes(
    nodes: list[dict[str, Any]],
    relations: list[dict[str, Any]],
    tenant_id: str = "default",
) -> dict[str, Any]:
    """
    Insert or merge graph nodes and relations into Neo4j without using an LLM API key.
    Nodes must have a 'type' (label) and 'name', plus optional 'properties'.
    Relations must have 'from_entity', 'to_entity' (names), 'type', and optional 'properties'.
    Existing nodes are matched/merged by name and tenant_id, avoiding duplicates and
    preserving cross-database links to Qdrant.
    """
    config = get_config()
    neo4j_client = Neo4jStorageClient.from_config(config)

    entity_name_to_node_id = {}
    nodes_inserted = 0
    relations_inserted = 0

    try:
        # 1. Upsert/Merge nodes
        for node in nodes:
            node_type = node.get("type", "Entity")
            if not node_type.isalnum():
                node_type = "Entity"
            props = node.get("properties", {}).copy()
            name = node.get("name", "").strip()
            if not name:
                continue

            node_id = neo4j_client.upsert_entity(
                label=node_type,
                tenant_id=tenant_id,
                name=name,
                aliases=[name],
                properties=props,
                qdrant_point_ids=[],
            )
            nodes_inserted += 1
            entity_name_to_node_id[name] = node_id

        # 2. Insert relations
        for relation in relations:
            from_name = relation.get("from_entity")
            to_name = relation.get("to_entity")
            rel_type = relation.get("type", "RELATED_TO").upper()
            rel_props = relation.get("properties", {}).copy()
            rel_props["tenant_id"] = tenant_id

            if not rel_type.replace("_", "").isalnum():
                rel_type = "RELATED_TO"

            from_id = entity_name_to_node_id.get(from_name)
            to_id = entity_name_to_node_id.get(to_name)

            if from_id and to_id:
                neo4j_client.upsert_relationship(
                    from_id=from_id,
                    to_id=to_id,
                    rel_type=rel_type,
                    properties=rel_props,
                )
                relations_inserted += 1

        return {
            "status": "success",
            "nodes_processed": len(nodes),
            "nodes_new": nodes_inserted,
            "relations_inserted": relations_inserted,
        }
    finally:
        neo4j_client.close()


def purge_cooccurrence_relationships(
    tenant_id: str = "default",
    relationship_types: list[str] | None = None,
) -> dict[str, Any]:
    """
    Purges all raw uncurated co-occurrence relationships (e.g. 'WORKS_FOR', 'MENTIONED_WITH')
    for the specified tenant in Neo4j, clearing hairball noise while leaving all
    entity nodes and Qdrant vector links intact.
    """
    config = get_config()
    neo4j_client = Neo4jStorageClient.from_config(config)
    types_to_purge = relationship_types or [
        "WORKS_FOR",
        "MENTIONED_WITH",
        "ASSOCIATED_WITH",
        "RELATED_TO",
    ]
    try:
        query = """
        MATCH ()-[r]->()
        WHERE (r.tenant_id = $tenant_id OR r.tenant_id IS NULL)
          AND type(r) IN $types_to_purge
        DELETE r
        RETURN count(r) AS deleted_count
        """
        results = neo4j_client.execute_read(
            query, {"tenant_id": tenant_id, "types_to_purge": types_to_purge}
        )
        count = results[0]["deleted_count"] if results else 0
        return {"status": "success", "deleted_relationships": count}
    finally:
        neo4j_client.close()
