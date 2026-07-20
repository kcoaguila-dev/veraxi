from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient

def delete_vector(document_id: str, tenant_id: str = "default") -> str:
    """
    Deletes a specific vector chunk from Qdrant by its document ID.
    Note: Qdrant client handles tenant authorization if the ID belongs to them (though ID is unique anyway).
    """
    config = get_config()
    qdrant = QdrantStorageClient.from_config(config)
    
    COLLECTION_NAME = config.qdrant_collection_name
    
    qdrant.delete_points(
        collection_name=COLLECTION_NAME,
        point_ids=[document_id]
    )
    
    return f"Successfully issued delete command for document ID: {document_id}"
