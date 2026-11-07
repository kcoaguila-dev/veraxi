import logging
import sentry_sdk

from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient

logger = logging.getLogger(__name__)


def _cleanse_vector_from_neo4j(config, document_id: str, tenant_id: str) -> None:
    """Removes point ID from linked Neo4j nodes and purges empty :Chunk nodes."""
    try:
        from backend.storage.neo4j_client import Neo4jStorageClient

        neo4j = Neo4jStorageClient.from_config(config)
        update_query = """
        MATCH (n)
        WHERE n.tenant_id = $tenant_id AND $document_id IN coalesce(n.qdrant_point_ids, [])
        SET n.qdrant_point_ids = [pid IN n.qdrant_point_ids WHERE pid <> $document_id]
        WITH n
        WHERE 'Chunk' IN labels(n) AND size(n.qdrant_point_ids) = 0
        DETACH DELETE n
        """
        neo4j.execute_write(update_query, {"document_id": document_id, "tenant_id": tenant_id})
        neo4j.close()
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.warning(f"Could not purge vector point {document_id} from Neo4j nodes: {exc}")


def delete_vector(document_id: str, tenant_id: str = "default") -> str:
    """
    Deletes a specific vector chunk from Qdrant by its document ID (scoped to tenant),
    and clears its reference from any linked Neo4j nodes.
    """
    config = get_config()
    qdrant = QdrantStorageClient.from_config(config)
    COLLECTION_NAME = config.qdrant_collection_name

    # Check whether the point belongs to this tenant
    points = qdrant.get_points(collection_name=COLLECTION_NAME, point_ids=[document_id])
    if not points:
        return f"Document ID '{document_id}' not found."

    pt = points[0]
    payload = pt.get("payload", {})
    if payload.get("tenant_id") and payload.get("tenant_id") != tenant_id:
        return f"Unauthorized: Document ID '{document_id}' does not belong to tenant '{tenant_id}'."

    qdrant.delete_points(collection_name=COLLECTION_NAME, point_ids=[document_id])

    # Cleanse reference from Neo4j nodes
    _cleanse_vector_from_neo4j(config, document_id, tenant_id)

    return f"Successfully issued delete command for document ID: {document_id}"
