import logging
from typing import Any

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
    WHERE n.name = $name
       OR toLower(n.name) IN $lower_candidates
       OR ($ent_key IS NOT NULL AND n.entity_key = $ent_key)
       OR ($is_short_token AND n.acronym_key = $norm_stripped)
       OR ($acr_ent_key IS NOT NULL AND n.entity_key = $acr_ent_key)
       OR any(a IN coalesce(n.aliases, []) WHERE toLower(a) IN $lower_candidates)
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

            existing_id = _find_existing_node_id(
                neo4j_client,
                tenant_id=tenant_id,
                name=name,
                node_type=node_type,
                aliases=aliases,
            )
            if existing_id:
                node_id = existing_id
                # Update properties while preserving canonical entity_key and merging aliases
                update_props = {
                    k: v
                    for k, v in props.items()
                    if k not in {"entity_key", "name", "aliases"}
                }
                update_query = """
                MATCH (n {id: $node_id, tenant_id: $tenant_id})
                SET n += $props,
                    n.entity_key = coalesce(n.entity_key, $entity_key),
                    n.aliases = reduce(acc = coalesce(n.aliases, []), a IN $aliases | CASE WHEN a IN acc THEN acc ELSE acc + a END)
                """
                neo4j_client.execute_write(
                    update_query,
                    {
                        "node_id": node_id,
                        "tenant_id": tenant_id,
                        "props": update_props,
                        "entity_key": props["entity_key"],
                        "aliases": aliases,
                    },
                )
            else:
                props["aliases"] = aliases
                node_id = neo4j_client.create_node(node_type, props)
                nodes_inserted += 1

            entity_name_to_node_id[name] = node_id
            for alias in aliases:
                entity_name_to_node_id.setdefault(alias, node_id)

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
            from_id = entity_name_to_node_id.get(from_name) if from_name else None
            if not from_id and from_name:
                from_id = _find_existing_node_id(
                    neo4j_client, tenant_id=tenant_id, name=from_name
                )
                if from_id:
                    entity_name_to_node_id[from_name] = from_id

            # Resolve to_id
            to_id = entity_name_to_node_id.get(to_name) if to_name else None
            if not to_id and to_name:
                to_id = _find_existing_node_id(
                    neo4j_client, tenant_id=tenant_id, name=to_name
                )
                if to_id:
                    entity_name_to_node_id[to_name] = to_id

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
