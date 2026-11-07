import logging
import sentry_sdk

from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient

logger = logging.getLogger(__name__)


def _scrub_entity_from_qdrant_points(
    config,
    neo4j_client: Neo4jStorageClient,
    all_q_ids: list[str],
    all_node_ids: set[str],
    names_to_scrub: set[str],
    tenant_id: str,
) -> None:
    """Removes references to deleted Neo4j entity and node IDs from linked Qdrant points.

    If a point's neo4j_node_ids becomes empty, creates an unlinked :Chunk node in Neo4j
    to preserve the dual-engine link invariant.
    """
    if not all_q_ids:
        return
    try:
        from backend.storage.qdrant_client import QdrantStorageClient

        qdrant = QdrantStorageClient.from_config(config)
        points = qdrant.get_points(config.qdrant_collection_name, all_q_ids)
        lower_scrub = {n.lower() for n in names_to_scrub}
        updates_by_point_id: dict[str, dict] = {}
        for pt in points:
            pid = pt.get("id")
            if not pid:
                continue
            payload = pt.get("payload", {})
            curr_nids = payload.get("neo4j_node_ids", [])
            curr_names = payload.get("entity_names", [])
            new_nids = [nid for nid in curr_nids if nid not in all_node_ids]
            new_names = [nm for nm in curr_names if nm.lower() not in lower_scrub]

            if not new_nids:
                # Maintain dual-engine link invariant: points must map to a Neo4j node
                chunk_node_id = neo4j_client.upsert_entity(
                    label="Chunk",
                    tenant_id=tenant_id,
                    name=f"UnlinkedChunk_{pid[:8]}",
                    aliases=[],
                    properties={},
                    qdrant_point_ids=[pid],
                )
                new_nids = [chunk_node_id]

            update_dict: dict = {"neo4j_node_ids": new_nids, "entity_names": new_names}
            if new_names:
                update_dict["entity_name"] = new_names[0]
            else:
                update_dict["entity_name"] = None
            updates_by_point_id[pid] = update_dict

        if updates_by_point_id:
            qdrant.batch_set_payloads(
                collection_name=config.qdrant_collection_name,
                payload_by_point_id=updates_by_point_id,
            )
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.warning(
            f"Could not purge entity {names_to_scrub} from Qdrant payloads: {exc}"
        )


def delete_entity(entity_name: str, tenant_id: str = "default") -> str:
    """Deletes an entity (node) and all its connected relationships from Neo4j,

    and cleanses references to this entity from linked Qdrant points.
    """
    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)

    fetch_query = """
    MATCH (n:Entity {tenant_id: $tenant_id})
    WHERE (toLower(n.name) = toLower($entity_name) OR any(a IN coalesce(n.aliases, []) WHERE toLower(a) = toLower($entity_name)))
    RETURN n.id AS id, n.name AS name, coalesce(n.aliases, []) AS aliases, coalesce(n.qdrant_point_ids, []) AS q_ids
    """

    delete_query = """
    MATCH (n:Entity {tenant_id: $tenant_id})
    WHERE (toLower(n.name) = toLower($entity_name) OR any(a IN coalesce(n.aliases, []) WHERE toLower(a) = toLower($entity_name)))
    DETACH DELETE n
    RETURN count(n) AS deleted_count
    """

    try:
        params = {"entity_name": entity_name, "tenant_id": tenant_id}
        records = neo4j.execute_read(fetch_query, params)
        all_node_ids = {r["id"] for r in records if r.get("id")}
        all_q_ids = [qid for r in records for qid in r.get("q_ids", [])]

        names_to_scrub = {entity_name}
        for r in records:
            if r.get("name"):
                names_to_scrub.add(r["name"])
            for alias in r.get("aliases", []):
                if alias:
                    names_to_scrub.add(alias)

        results = neo4j.execute_write(delete_query, params)
        count = results[0]["deleted_count"] if results else 0

        # Clean up references inside Qdrant points
        _scrub_entity_from_qdrant_points(
            config, neo4j, all_q_ids, all_node_ids, names_to_scrub, tenant_id
        )

        return f"Successfully deleted {count} entity(s) matching '{entity_name}'."
    finally:
        neo4j.close()
