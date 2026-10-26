from typing import Any
import logging
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
            props["name"] = name
            props["tenant_id"] = tenant_id

            # Check if node already exists for this tenant
            match_query = """
            MATCH (n {name: $name, tenant_id: $tenant_id})
            RETURN n.id AS id
            LIMIT 1
            """
            existing = neo4j_client.execute_read(
                match_query, {"name": name, "tenant_id": tenant_id}
            )
            if existing and existing[0].get("id"):
                node_id = existing[0]["id"]
                # Update properties if provided
                if props:
                    update_query = """
                    MATCH (n {id: $node_id, tenant_id: $tenant_id})
                    SET n += $props
                    """
                    neo4j_client.execute_write(
                        update_query,
                        {
                            "node_id": node_id,
                            "tenant_id": tenant_id,
                            "props": props,
                        },
                    )
            else:
                node_id = neo4j_client.create_node(node_type, props)
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

            # Resolve from_id
            from_id = entity_name_to_node_id.get(from_name)
            if not from_id and from_name:
                match_from = neo4j_client.execute_read(
                    "MATCH (n {name: $name, tenant_id: $tenant_id}) RETURN n.id AS id LIMIT 1",
                    {"name": from_name, "tenant_id": tenant_id},
                )
                if match_from and match_from[0].get("id"):
                    from_id = match_from[0]["id"]
                    entity_name_to_node_id[from_name] = from_id

            # Resolve to_id
            to_id = entity_name_to_node_id.get(to_name)
            if not to_id and to_name:
                match_to = neo4j_client.execute_read(
                    "MATCH (n {name: $name, tenant_id: $tenant_id}) RETURN n.id AS id LIMIT 1",
                    {"name": to_name, "tenant_id": tenant_id},
                )
                if match_to and match_to[0].get("id"):
                    to_id = match_to[0]["id"]
                    entity_name_to_node_id[to_name] = to_id

            if from_id and to_id:
                # Merge relationship to prevent duplicates, setting causal properties and tenant_id
                merge_rel_query = f"""
                MATCH (a {{id: $from_id, tenant_id: $tenant_id}})
                MATCH (b {{id: $to_id, tenant_id: $tenant_id}})
                MERGE (a)-[r:{rel_type}]->(b)
                SET r += $rel_props
                """
                neo4j_client.execute_write(
                    merge_rel_query,
                    {
                        "from_id": from_id,
                        "to_id": to_id,
                        "tenant_id": tenant_id,
                        "rel_props": rel_props,
                    },
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
