from typing import List, Dict, Any
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.config import get_config

def insert_graph_nodes(
    nodes: List[Dict[str, Any]],
    relations: List[Dict[str, str]],
    tenant_id: str = "default"
) -> Dict[str, Any]:
    """
    Insert raw graph nodes and relations into Neo4j without using an LLM API key.
    Nodes must have a 'type' (label) and 'name', plus any 'properties'.
    Relations must have 'from_entity', 'to_entity' (names), and 'type'.
    """
    config = get_config()
    neo4j_client = Neo4jStorageClient.from_config(config)

    entity_name_to_node_id = {}
    nodes_inserted = 0
    relations_inserted = 0

    try:
        for node in nodes:
            node_type = node.get("type", "Entity")
            props = node.get("properties", {}).copy()
            name = node.get("name", "Unknown")
            props["name"] = name
            props["tenant_id"] = tenant_id
            
            node_id = neo4j_client.create_node(node_type, props)
            entity_name_to_node_id[name] = node_id
            nodes_inserted += 1

        for relation in relations:
            from_name = relation.get("from_entity")
            to_name = relation.get("to_entity")
            rel_type = relation.get("type", "RELATED_TO")

            from_id = entity_name_to_node_id.get(from_name)
            to_id = entity_name_to_node_id.get(to_name)

            if from_id and to_id:
                neo4j_client.create_relationship(from_id, to_id, rel_type)
                relations_inserted += 1

        return {
            "status": "success",
            "nodes_inserted": nodes_inserted,
            "relations_inserted": relations_inserted
        }
    finally:
        neo4j_client.close()
