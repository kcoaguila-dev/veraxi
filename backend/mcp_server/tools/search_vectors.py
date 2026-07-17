from typing import List
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.ingestion.chunk_embed import embed_text
from backend.retrieval.merge_rank import VectorHit


def search_vectors(
    query_text: str, limit: int = 10, tenant_id: str = "default"
) -> List[VectorHit]:
    """
    Search Qdrant vectors using similarity search.
    Embeds the query_text, performs a vector search, and returns VectorHit objects ready for merge_rank.
    """
    config = get_config()
    qdrant_client = QdrantStorageClient(config.qdrant_url, config.qdrant_api_key)
    
    COLLECTION_NAME = config.qdrant_collection_name

    # Embed the query
    query_vector = embed_text(query_text)

    # Perform search
    results = qdrant_client.search(
        collection_name=COLLECTION_NAME,
        query_vector=query_vector,
        limit=limit,
        tenant_id=tenant_id,
    )

    # Return as VectorHit objects
    hits = []
    for hit in results:
        hits.append(VectorHit(id=hit["id"], score=hit["score"], payload=hit["payload"]))
    return hits
