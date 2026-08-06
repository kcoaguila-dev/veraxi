from typing import List
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.ingestion.chunk_embed import embed_text, embed_text_sparse
from backend.retrieval.merge_rank import VectorHit


def search_vectors(
    query_text: str, limit: int = 10, tenant_id: str = "default"
) -> List[VectorHit]:
    """
    Search Qdrant vectors using Hybrid Search (Dense + Sparse).
    Embeds the query_text, performs a hybrid search, and returns VectorHit objects ready for merge_rank.
    """
    config = get_config()
    qdrant_client = QdrantStorageClient.from_config(config)
    
    COLLECTION_NAME = config.qdrant_collection_name

    # Embed the query
    query_vector = embed_text(query_text)
    sparse_query_vector = embed_text_sparse(query_text)

    # Perform search
    results = qdrant_client.search_hybrid(
        collection_name=COLLECTION_NAME,
        query_vector=query_vector,
        sparse_query_vector=sparse_query_vector,
        limit=limit,
        tenant_id=tenant_id,
    )

    # Return as VectorHit objects
    hits = []
    for hit in results:
        hits.append(VectorHit(id=hit["id"], score=hit["score"], payload=hit["payload"]))
    return hits
