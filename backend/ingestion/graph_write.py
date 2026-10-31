from dataclasses import dataclass
from typing import Any

from backend.storage.neo4j_client import Neo4jStorageClient


@dataclass
class IngestionPayload:
    entities: list[dict[str, Any]]
    relations: list[dict[str, str]]
    qdrant_point_ids: dict[str, str]


from backend.ingestion.entity_resolution import normalize_name


def _create_unlinked_chunks(
    neo4j_client: Neo4jStorageClient,
    unlinked_point_ids: list[str],
    tenant_id: str,
):
    for i, qdrant_id in enumerate(unlinked_point_ids):
        neo4j_client.upsert_entity(
            label="Chunk",
            tenant_id=tenant_id,
            name=f"UnlinkedChunk_{qdrant_id[:8]}",
            aliases=[],
            properties={},
            qdrant_point_ids=[qdrant_id],
        )


def write_to_graph(
    neo4j_client: Neo4jStorageClient,
    payload: IngestionPayload,
    tenant_id: str = "default",
) -> tuple[dict[str, str], dict[str, list[str]]]:
    """
    Write entities and relations to Neo4j, linking to Qdrant point IDs.
    Returns a tuple of (entity_name_to_node_id, qdrant_id_to_neo4j_ids).
    """
    entity_name_to_node_id: dict[str, str] = {}
    qdrant_id_to_neo4j_ids: dict[str, list[str]] = {}

    if not payload.qdrant_point_ids:
        raise ValueError("Must provide at least one qdrant_point_id to link nodes.")

    # Match chunk texts to surface aliases to map qdrant_point_ids to canonical entities
    linked_qdrant_ids = set()

    for entity in payload.entities:
        name = entity["name"]
        aliases = list({name} | set(entity.get("aliases", [])))

        # Find which chunks contain any of this entity's aliases
        matched_point_ids = []
        for chunk_text, point_id in payload.qdrant_point_ids.items():
            chunk_text_norm = normalize_name(chunk_text)
            for alias in aliases:
                if normalize_name(alias) in chunk_text_norm:
                    matched_point_ids.append(point_id)
                    linked_qdrant_ids.add(point_id)
                    break  # Once we link the chunk to this entity, move to next chunk

        # Ensure we always link at least one chunk if available and none matched
        if not matched_point_ids and payload.qdrant_point_ids:
            # Fallback to the first chunk
            first_point_id = next(iter(payload.qdrant_point_ids.values()))
            matched_point_ids = [first_point_id]
            linked_qdrant_ids.add(first_point_id)

        node_id = neo4j_client.upsert_entity(
            label=entity["type"],
            tenant_id=tenant_id,
            name=name,
            aliases=aliases,
            properties=entity.get("properties", {}),
            qdrant_point_ids=matched_point_ids,
        )

        entity_name_to_node_id[name] = node_id

        for pid in matched_point_ids:
            if pid not in qdrant_id_to_neo4j_ids:
                qdrant_id_to_neo4j_ids[pid] = []
            qdrant_id_to_neo4j_ids[pid].append(node_id)

    # Ensure every Qdrant point is stored in Neo4j (critical link requirement)
    all_point_ids = set(payload.qdrant_point_ids.values())
    unlinked = list(all_point_ids - linked_qdrant_ids)
    if unlinked:
        _create_unlinked_chunks(neo4j_client, unlinked, tenant_id)

    for relation in payload.relations:
        from_node_id = entity_name_to_node_id.get(relation["from_entity"])
        to_node_id = entity_name_to_node_id.get(relation["to_entity"])

        if from_node_id and to_node_id:
            neo4j_client.upsert_relationship(
                from_id=from_node_id,
                to_id=to_node_id,
                rel_type=relation["type"],
                properties={"tenant_id": tenant_id},
            )

    return entity_name_to_node_id, qdrant_id_to_neo4j_ids
