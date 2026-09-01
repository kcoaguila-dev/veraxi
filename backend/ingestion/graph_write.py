from dataclasses import dataclass
from typing import Any

from backend.storage.neo4j_client import Neo4jStorageClient


@dataclass
class IngestionPayload:
    entities: list[dict[str, Any]]
    relations: list[dict[str, str]]
    qdrant_point_ids: dict[str, str]


def _create_unlinked_chunks(
    neo4j_client: Neo4jStorageClient,
    point_ids: list[str],
    start_idx: int,
    tenant_id: str,
):
    for i in range(start_idx, len(point_ids)):
        qdrant_id = point_ids[i]
        props = {
            "name": f"UnlinkedChunk_{i}",
            "qdrant_point_id": qdrant_id,
            "tenant_id": tenant_id,
        }
        neo4j_client.create_node("Chunk", props)


def write_to_graph(
    neo4j_client: Neo4jStorageClient,
    payload: IngestionPayload,
    tenant_id: str = "default",
) -> dict[str, str]:
    """
    Write entities and relations to Neo4j, linking to Qdrant point IDs.
    Returns a tuple of (entity_name_to_node_id, qdrant_id_to_neo4j_ids).
    """
    entity_name_to_node_id = {}
    qdrant_id_to_neo4j_ids = {}

    if not payload.qdrant_point_ids:
        raise ValueError("Must provide at least one qdrant_point_id to link nodes.")

    point_ids = list(payload.qdrant_point_ids.values())

    for i, entity in enumerate(payload.entities):
        props = entity.get("properties", {}).copy()
        props["name"] = entity["name"]

        # Link to qdrant - cycle through available qdrant points if there are more nodes than points
        qdrant_id = point_ids[i % len(point_ids)]
        props["qdrant_point_id"] = qdrant_id
        props["tenant_id"] = tenant_id

        node_id = neo4j_client.create_node(entity["type"], props)
        entity_name_to_node_id[entity["name"]] = node_id
        
        if qdrant_id not in qdrant_id_to_neo4j_ids:
            qdrant_id_to_neo4j_ids[qdrant_id] = []
        qdrant_id_to_neo4j_ids[qdrant_id].append(node_id)

    # Ensure every Qdrant point is stored in Neo4j (critical link requirement)
    if len(point_ids) > len(payload.entities):
        _create_unlinked_chunks(
            neo4j_client, point_ids, len(payload.entities), tenant_id
        )

    for relation in payload.relations:
        from_node_id = entity_name_to_node_id.get(relation["from_entity"])
        to_node_id = entity_name_to_node_id.get(relation["to_entity"])

        if from_node_id and to_node_id:
            neo4j_client.create_relationship(from_node_id, to_node_id, relation["type"])

    return entity_name_to_node_id, qdrant_id_to_neo4j_ids
