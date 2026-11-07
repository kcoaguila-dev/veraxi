from typing import Any

from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient


def update_document_metadata(
    document_id: str, payload: dict[str, Any], tenant_id: str = "default"
) -> str:
    """
    Updates the payload (metadata) of an existing vector in Qdrant after verifying tenant ownership.
    """
    config = get_config()
    qdrant = QdrantStorageClient.from_config(config)
    COLLECTION_NAME = config.qdrant_collection_name

    # Check whether the point belongs to this tenant
    points = qdrant.get_points(collection_name=COLLECTION_NAME, point_ids=[document_id])
    if not points:
        return f"Document ID '{document_id}' not found."

    pt = points[0]
    existing_payload = pt.get("payload", {}) if isinstance(pt, dict) else getattr(pt, "payload", {})
    if existing_payload.get("tenant_id") and existing_payload.get("tenant_id") != tenant_id:
        return f"Unauthorized: Document ID '{document_id}' does not belong to tenant '{tenant_id}'."

    # Strip reserved internal link properties to prevent corrupting graph/vector mapping
    safe_payload = {
        k: v
        for k, v in (payload or {}).items()
        if k not in {"tenant_id", "neo4j_node_ids", "file_hash"}
    }
    safe_payload["tenant_id"] = tenant_id

    qdrant.client.set_payload(
        collection_name=COLLECTION_NAME, payload=safe_payload, points=[document_id]
    )

    return f"Successfully updated metadata payload for document ID: {document_id}"
