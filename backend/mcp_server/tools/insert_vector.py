from typing import List, Dict, Any
from backend.storage.qdrant_client import QdrantStorageClient
from backend.config import get_config
from backend.ingestion.chunk_embed import embed_text

def insert_vectors(
    texts: List[str],
    tenant_id: str = "default"
) -> Dict[str, Any]:
    """
    Generate embeddings for raw texts using local models and insert into Qdrant.
    Does not require a Gemini API key.
    """
    config = get_config()
    qdrant_client = QdrantStorageClient.from_config(config)
    COLLECTION_NAME = config.qdrant_collection_name
    qdrant_client.create_collection(COLLECTION_NAME)

    vectors = []
    payloads = []

    for text in texts:
        vector = embed_text(text)
        vectors.append(vector)
        payloads.append({
            "text": text,
            "tenant_id": tenant_id
        })

    if vectors:
        point_ids = qdrant_client.insert_points(
            collection_name=COLLECTION_NAME,
            vectors=vectors,
            payloads=payloads,
            tenant_id=tenant_id
        )
        return {
            "status": "success",
            "vectors_inserted": len(point_ids),
            "point_ids": point_ids
        }
    
    return {
        "status": "success",
        "vectors_inserted": 0,
        "point_ids": []
    }
