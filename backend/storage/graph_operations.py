import logging
from typing import Any

import sentry_sdk

from backend.config import get_config
from backend.ingestion.entity_resolution import (
    acronym_of,
    entity_key,
    normalize_name,
    strip_generic_suffix,
)
from backend.storage.neo4j_client import Neo4jStorageClient

logger = logging.getLogger(__name__)


def _find_existing_node_id(
    neo4j_client: Neo4jStorageClient,
    tenant_id: str,
    name: str,
    node_type: str | None = None,
    aliases: list[str] | None = None,
) -> str | None:
    """Find an existing node in Neo4j by exact name, entity_key, acronym_key, or aliases."""
    norm_name = normalize_name(name)
    norm_stripped = strip_generic_suffix(norm_name)
    acr_key = acronym_of(norm_name)
    lower_candidates = list(
        {name.strip().lower(), norm_stripped}
        | {
            a.strip().lower()
            for a in (aliases or [])
            if isinstance(a, str) and a.strip()
        }
    )
    ent_key = entity_key(tenant_id, node_type, name) if node_type else None
    acr_ent_key = (
        f"{tenant_id}::{node_type}::{acr_key}" if (node_type and acr_key) else None
    )

    match_query = """
    MATCH (n {tenant_id: $tenant_id})
    WHERE (n:Entity OR NOT n:Chunk)
      AND (
        n.name = $name
        OR toLower(n.name) IN $lower_candidates
        OR ($ent_key IS NOT NULL AND n.entity_key = $ent_key)
        OR ($is_short_token AND n.acronym_key = $norm_stripped)
        OR ($acr_ent_key IS NOT NULL AND n.entity_key = $acr_ent_key)
        OR any(a IN coalesce(n.aliases, []) WHERE toLower(a) IN $lower_candidates)
      )
    RETURN n.id AS id
    LIMIT 1
    """
    existing = neo4j_client.execute_read(
        match_query,
        {
            "tenant_id": tenant_id,
            "name": name,
            "lower_candidates": lower_candidates,
            "ent_key": ent_key,
            "is_short_token": (
                2 <= len(norm_stripped) <= 6 and " " not in norm_stripped
            ),
            "norm_stripped": norm_stripped,
            "acr_ent_key": acr_ent_key,
        },
    )
    if existing and existing[0].get("id"):
        return existing[0]["id"]
    return None


def _backpropagate_links_to_qdrant(
    config, qdrant_links: dict[str, tuple[list[str], list[str]]]
) -> None:
    """Batch updates Qdrant points with new neo4j_node_ids and entity_names."""
    if not qdrant_links:
        return
    try:
        from backend.storage.qdrant_client import QdrantStorageClient

        qdrant_client = QdrantStorageClient.from_config(config)
        all_point_ids = list(qdrant_links.keys())
        existing_points = qdrant_client.get_points(config.qdrant_collection_name, all_point_ids)
        updates_by_point_id: dict[str, dict] = {}
        for pt in existing_points:
            pt_id = pt.get("id")
            if not pt_id or pt_id not in qdrant_links:
                continue
            add_nids, add_names = qdrant_links[pt_id]
            pt_payload = pt.get("payload", {})
            merged_nids = list(dict.fromkeys(pt_payload.get("neo4j_node_ids", []) + add_nids))
            merged_names = list(dict.fromkeys(pt_payload.get("entity_names", []) + add_names))
            updates_by_point_id[pt_id] = {
                "neo4j_node_ids": merged_nids,
                "entity_names": merged_names,
                "entity_name": merged_names[0] if merged_names else None,
            }
        qdrant_client.batch_set_payloads(
            collection_name=config.qdrant_collection_name,
            payload_by_point_id=updates_by_point_id,
        )
    except Exception as q_exc:
        sentry_sdk.capture_exception(q_exc)
        logger.warning(f"Could not back-propagate links to Qdrant: {q_exc}")


def _upsert_single_graph_node(
    neo4j_client: Neo4jStorageClient,
    node: dict[str, Any],
    tenant_id: str,
) -> tuple[str, str, list[str], list[str], bool] | None:
    """Upsert or merge a single graph node, returning (node_id, name, aliases, q_point_ids, is_created)."""
    node_type = node.get("type", "Entity")
    if not node_type.isalnum():
        node_type = "Entity"
    props = node.get("properties", {}).copy()
    name = node.get("name", "").strip()
    if not name:
        return None

    raw_aliases = node.get("aliases", [])
    aliases = list(
        {name}
        | {
            str(a).strip()
            for a in (raw_aliases if isinstance(raw_aliases, list) else [])
            if isinstance(a, str) and str(a).strip()
        }
    )
    norm_name = normalize_name(name)
    props["name"] = name
    props["tenant_id"] = tenant_id
    props["entity_key"] = entity_key(tenant_id, node_type, name)
    acr_key = acronym_of(norm_name)
    if acr_key:
        props["acronym_key"] = acr_key
    q_point_ids = node.get("qdrant_point_ids") or props.get("qdrant_point_ids") or []
    if isinstance(q_point_ids, list):
        props["qdrant_point_ids"] = q_point_ids

    existing_id = _find_existing_node_id(
        neo4j_client,
        tenant_id=tenant_id,
        name=name,
        node_type=node_type,
        aliases=aliases,
    )
    if existing_id:
        node_id = existing_id
        update_props = {
            k: v
            for k, v in props.items()
            if k not in {"entity_key", "name", "aliases", "qdrant_point_ids"}
        }
        update_query = """
        MATCH (n {id: $node_id, tenant_id: $tenant_id})
        SET n:Entity,
            n += $props,
            n.entity_key = coalesce(n.entity_key, $entity_key),
            n.aliases = reduce(acc = coalesce(n.aliases, []), a IN $aliases | CASE WHEN a IN acc THEN acc ELSE acc + a END),
            n.qdrant_point_ids = reduce(acc = coalesce(n.qdrant_point_ids, []), p IN $q_point_ids | CASE WHEN p IN acc THEN acc ELSE acc + p END)
        """
        neo4j_client.execute_write(
            update_query,
            {
                "node_id": node_id,
                "tenant_id": tenant_id,
                "props": update_props,
                "entity_key": props["entity_key"],
                "aliases": aliases,
                "q_point_ids": q_point_ids,
            },
        )
        is_created = False
    else:
        props["aliases"] = aliases
        node_id = neo4j_client.create_node(node_type, props)
        is_created = True

    return node_id, name, aliases, q_point_ids, is_created


def _upsert_single_graph_relation(
    neo4j_client: Neo4jStorageClient,
    relation: dict[str, Any],
    entity_name_to_node_id: dict[str, str],
    tenant_id: str,
) -> bool:
    """Upsert or merge a single graph relationship. Returns True if created/updated."""
    from_name = relation.get("from_entity")
    to_name = relation.get("to_entity")
    rel_type = relation.get("type", "RELATED_TO").upper()
    rel_props = relation.get("properties", {}).copy()
    rel_props["tenant_id"] = tenant_id

    if not rel_type.replace("_", "").isalnum():
        rel_type = "RELATED_TO"

    from_id = entity_name_to_node_id.get(from_name) if from_name else None
    if not from_id and from_name:
        from_id = _find_existing_node_id(neo4j_client, tenant_id=tenant_id, name=from_name)
        if from_id:
            entity_name_to_node_id[from_name] = from_id

    to_id = entity_name_to_node_id.get(to_name) if to_name else None
    if not to_id and to_name:
        to_id = _find_existing_node_id(neo4j_client, tenant_id=tenant_id, name=to_name)
        if to_id:
            entity_name_to_node_id[to_name] = to_id

    if not from_id or not to_id:
        return False

    neo4j_client.upsert_relationship(
        from_id=from_id,
        to_id=to_id,
        rel_type=rel_type,
        properties=rel_props,
    )
    return True


def insert_graph_nodes(
    nodes: list[dict[str, Any]],
    relations: list[dict[str, Any]],
    tenant_id: str = "default",
) -> dict[str, Any]:
    """
    Insert or merge graph nodes and relations into Neo4j without using an LLM API key.
    Nodes must have a 'type' (label) and 'name', plus optional 'properties'.
    Relations must have 'from_entity', 'to_entity' (names), 'type', and optional 'properties'.
    Existing nodes are matched/merged by name, entity_key, acronym, and aliases for the tenant_id,
    avoiding duplicates and preserving cross-database links to Qdrant.
    """
    config = get_config()
    neo4j_client = Neo4jStorageClient.from_config(config)

    entity_name_to_node_id: dict[str, str] = {}
    qdrant_links: dict[str, tuple[list[str], list[str]]] = {}
    nodes_inserted = 0
    relations_inserted = 0

    try:
        # 1. Upsert/Merge nodes
        for node in nodes:
            res = _upsert_single_graph_node(neo4j_client, node, tenant_id)
            if not res:
                continue
            node_id, name, aliases, q_point_ids, is_created = res
            if is_created:
                nodes_inserted += 1

            entity_name_to_node_id[name] = node_id
            for alias in aliases:
                entity_name_to_node_id.setdefault(alias, node_id)

            if q_point_ids:
                for pid in q_point_ids:
                    if pid not in qdrant_links:
                        qdrant_links[pid] = ([], [])
                    qdrant_links[pid][0].append(node_id)
                    qdrant_links[pid][1].append(name)

        # Back-propagate links to Qdrant points in a single batch
        _backpropagate_links_to_qdrant(config, qdrant_links)

        # 2. Insert relations
        for relation in relations:
            if _upsert_single_graph_relation(
                neo4j_client, relation, entity_name_to_node_id, tenant_id
            ):
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
