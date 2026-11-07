import logging
from dataclasses import dataclass
from typing import Any

from backend.storage.neo4j_client import Neo4jStorageClient

logger = logging.getLogger(__name__)


@dataclass
class IngestionPayload:
    entities: list[dict[str, Any]]
    relations: list[dict[str, str]]
    qdrant_point_ids: dict[str, str] | list[tuple[str, str]]
    source: str | None = None


from backend.ingestion.entity_resolution import (
    acronym_candidates,
    normalize_name,
)


def _alias_matches_chunk(
    norm_alias: str, chunk_text_norm: str, chunk_tokens: set[str]
) -> bool:
    """Checks if a normalized alias appears as a whole token or exact phrase within a chunk."""
    if not norm_alias or not chunk_text_norm:
        return False
    if " " in norm_alias:
        return f" {norm_alias} " in f" {chunk_text_norm} "
    return norm_alias in chunk_tokens


def _create_unlinked_chunks(
    neo4j_client: Neo4jStorageClient,
    unlinked_point_ids: list[str],
    tenant_id: str,
) -> dict[str, str]:
    chunk_nodes: dict[str, str] = {}
    for i, qdrant_id in enumerate(unlinked_point_ids):
        node_id = neo4j_client.upsert_entity(
            label="Chunk",
            tenant_id=tenant_id,
            name=f"UnlinkedChunk_{qdrant_id[:8]}",
            aliases=[],
            properties={},
            qdrant_point_ids=[qdrant_id],
        )
        chunk_nodes[qdrant_id] = node_id
    return chunk_nodes


def _match_entity_to_chunks(
    entity: dict[str, Any],
    norm_chunks: list[tuple[str, set[str], str]],
    all_point_ids: set[str],
) -> list[str]:
    """Matches an entity to corresponding chunk point IDs using extraction provenance, aliases, and acronyms."""
    name = entity.get("name", "")
    matched: list[str] = []

    # 1. Direct provenance from chunk-level extraction
    source_pids = entity.get("source_point_ids") or []
    valid_source_pids = [pid for pid in source_pids if pid in all_point_ids]
    if valid_source_pids:
        matched.extend(valid_source_pids)

    # 2. Exact word boundary / phrase matching on normalized aliases
    aliases = list({name} | set(entity.get("aliases", [])))
    norm_aliases = [normalize_name(a) for a in aliases if normalize_name(a)]

    for chunk_text_norm, chunk_tokens, point_id in norm_chunks:
        if point_id not in matched and any(
            _alias_matches_chunk(norm_a, chunk_text_norm, chunk_tokens)
            for norm_a in norm_aliases
        ):
            matched.append(point_id)

    # 3. Content-token and acronym matching fallback
    if not matched:
        norm_n = normalize_name(name)
        name_tokens = {w for w in norm_n.split() if len(w) >= 3}
        acrs = {a.lower() for a in acronym_candidates(norm_n)}
        match_candidates = name_tokens | acrs
        if match_candidates:
            for chunk_text_norm, chunk_tokens, point_id in norm_chunks:
                if match_candidates & chunk_tokens:
                    matched.append(point_id)

    # 4. Fallback only for single-chunk documents; multi-chunk documents avoid false attribution
    if not matched:
        if len(all_point_ids) == 1:
            matched.append(next(iter(all_point_ids)))
        elif len(all_point_ids) > 1:
            logger.debug(
                "Entity '%s' could not be resolved to a specific chunk in multi-chunk document; leaving unlinked to preserve citation precision.",
                name,
            )

    return list(dict.fromkeys(matched))


def write_to_graph(
    neo4j_client: Neo4jStorageClient,
    payload: IngestionPayload,
    tenant_id: str = "default",
) -> tuple[dict[str, str], dict[str, list[str]], dict[str, list[str]]]:
    """
    Write entities and relations to Neo4j, linking to Qdrant point IDs.
    Returns a tuple of (entity_name_to_node_id, qdrant_id_to_neo4j_ids, qdrant_id_to_entity_names).
    """
    entity_name_to_node_id: dict[str, str] = {}
    qdrant_id_to_neo4j_ids: dict[str, list[str]] = {}
    qdrant_id_to_entity_names: dict[str, list[str]] = {}

    if not payload.qdrant_point_ids:
        raise ValueError("Must provide at least one qdrant_point_id to link nodes.")

    if isinstance(payload.qdrant_point_ids, dict):
        chunk_items = list(payload.qdrant_point_ids.items())
        all_point_ids = set(payload.qdrant_point_ids.values())
    else:
        chunk_items = list(payload.qdrant_point_ids)
        all_point_ids = {pid for _, pid in chunk_items}

    linked_qdrant_ids = set()

    # Pre-normalize chunk texts and tokens once to avoid quadratic repeated regexes across all entities
    norm_chunks = [
        (
            normalize_name(chunk_text),
            set(normalize_name(chunk_text).split()),
            point_id,
        )
        for chunk_text, point_id in chunk_items
    ]

    for entity in payload.entities:
        name = entity["name"]
        aliases = list({name} | set(entity.get("aliases", [])))
        matched_point_ids = _match_entity_to_chunks(entity, norm_chunks, all_point_ids)
        linked_qdrant_ids.update(matched_point_ids)

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
            if pid not in qdrant_id_to_entity_names:
                qdrant_id_to_entity_names[pid] = []
            if name not in qdrant_id_to_entity_names[pid]:
                qdrant_id_to_entity_names[pid].append(name)

    # Ensure every Qdrant point is stored in Neo4j (critical link requirement)
    unlinked = list(all_point_ids - linked_qdrant_ids)
    if unlinked:
        unlinked_nodes = _create_unlinked_chunks(neo4j_client, unlinked, tenant_id)
        for pid, nid in unlinked_nodes.items():
            if pid not in qdrant_id_to_neo4j_ids:
                qdrant_id_to_neo4j_ids[pid] = []
            qdrant_id_to_neo4j_ids[pid].append(nid)

    for relation in payload.relations:
        from_node_id = entity_name_to_node_id.get(relation["from_entity"])
        to_node_id = entity_name_to_node_id.get(relation["to_entity"])

        if from_node_id and to_node_id:
            rel_props = {"tenant_id": tenant_id}
            if payload.source:
                rel_props["source"] = payload.source
            neo4j_client.upsert_relationship(
                from_id=from_node_id,
                to_id=to_node_id,
                rel_type=relation["type"],
                properties=rel_props,
            )

    return entity_name_to_node_id, qdrant_id_to_neo4j_ids, qdrant_id_to_entity_names
