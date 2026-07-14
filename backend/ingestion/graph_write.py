from typing import List, Dict, Any

from backend.storage.neo4j_client import Neo4jStorageClient

def write_to_graph(neo4j_client: Neo4jStorageClient, entities: List[Dict[str, Any]], relations: List[Dict[str, str]], qdrant_point_ids: Dict[str, str], tenant_id: str = "default") -> Dict[str, str]:
    """
    Write entities and relations to Neo4j, linking to Qdrant point IDs.
    Returns a mapping from entity name to neo4j node ID.
    """
    entity_name_to_node_id = {}

    if not qdrant_point_ids:
        raise ValueError("Must provide at least one qdrant_point_id to link nodes.")

    point_ids = list(qdrant_point_ids.values())

    for i, entity in enumerate(entities):
        props = entity.get("properties", {}).copy()
        props["name"] = entity["name"]

        # Link to qdrant - cycle through available qdrant points if there are more nodes than points
        qdrant_id = point_ids[i % len(point_ids)]
        props["qdrant_point_id"] = qdrant_id
        props["tenant_id"] = tenant_id

        node_id = neo4j_client.create_node(entity["type"], props)
        entity_name_to_node_id[entity["name"]] = node_id

    # Ensure every Qdrant point is stored in Neo4j (critical link requirement)
    # If there are more point_ids than entities, we create standalone nodes for the unlinked chunks
    if len(point_ids) > len(entities):
        for i in range(len(entities), len(point_ids)):
            qdrant_id = point_ids[i]
            props = {"name": f"UnlinkedChunk_{i}", "qdrant_point_id": qdrant_id, "tenant_id": tenant_id}
            neo4j_client.create_node("Chunk", props)

    for relation in relations:
        from_node_id = entity_name_to_node_id.get(relation["from_entity"])
        to_node_id = entity_name_to_node_id.get(relation["to_entity"])

        if from_node_id and to_node_id:
            neo4j_client.create_relationship(from_node_id, to_node_id, relation["type"])

    return entity_name_to_node_id
