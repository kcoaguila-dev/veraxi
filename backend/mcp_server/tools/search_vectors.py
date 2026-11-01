from backend.config import get_config
from backend.ingestion.chunk_embed import embed_text, embed_text_sparse
from backend.retrieval.merge_rank import VectorHit
from backend.storage.qdrant_client import QdrantStorageClient


def search_vectors(
    query_text: str, limit: int = 10, tenant_id: str = "default"
) -> list[VectorHit]:
    """
    Search Qdrant vectors using Hybrid Search (Dense + Sparse).
    Embeds the query_text, performs a hybrid search, and returns VectorHit objects ready for merge_rank.
    """
    config = get_config()
    qdrant_client = QdrantStorageClient.from_config(config)

    COLLECTION_NAME = config.qdrant_collection_name

    # Embed the query in parallel (dense + sparse)
    from concurrent.futures import ThreadPoolExecutor

    with ThreadPoolExecutor(max_workers=2) as executor:
        future_dense = executor.submit(embed_text, query_text)
        future_sparse = executor.submit(embed_text_sparse, query_text)
        query_vector = future_dense.result()
        sparse_query_vector = future_sparse.result()

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
