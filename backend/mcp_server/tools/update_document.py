from typing import Dict, Any
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from qdrant_client.http import models

def update_document_metadata(document_id: str, payload: Dict[str, Any], tenant_id: str = "default") -> str:
    """
    Updates the payload (metadata) of an existing vector in Qdrant.
    """
    config = get_config()
    qdrant = QdrantStorageClient(url=config.qdrant_url, api_key=config.qdrant_api_key)
    COLLECTION_NAME = config.qdrant_collection_name
    
    # Ensure tenant_id remains enforced if they try to override it
    payload["tenant_id"] = tenant_id

    qdrant.client.set_payload(
        collection_name=COLLECTION_NAME,
        payload=payload,
        points=[document_id]
    )
    
    return f"Successfully updated metadata payload for document ID: {document_id}"
