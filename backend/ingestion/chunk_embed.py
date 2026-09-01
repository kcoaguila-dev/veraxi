

def chunk_text(text: str, chunk_size: int = 200, overlap: int = 50) -> list[str]:
    """Chunk text into segments of chunk_size with overlap."""
    if not text:
        return []

    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunks.append(text[start:end])
        if end >= len(text):
            break
        start = end - overlap

    return chunks


from functools import lru_cache


@lru_cache(maxsize=1)
def get_embedding_model():
    """Load model once and cache it"""
    from sentence_transformers import SentenceTransformer

    from backend.config import get_config
    config = get_config()
    return SentenceTransformer(config.embedding_model_name)


@lru_cache(maxsize=1)
def get_sparse_embedding_model():
    """Load sparse model once and cache it"""
    from fastembed import SparseTextEmbedding
    return SparseTextEmbedding(model_name="prithivida/Splade_PP_en_v1")


def embed_text(text: str) -> list[float]:
    """Embed text using local sentence-transformers model."""
    if not text:
        return [0.0] * 384
    
    model = get_embedding_model()
    # model.encode returns a numpy array, convert to list of floats
    embedding = model.encode(text)
    return embedding.tolist()


def embed_text_sparse(text: str) -> dict:
    """Embed text using local fastembed SPLADE model."""
    if not text:
        return {"indices": [], "values": []}
    
    model = get_sparse_embedding_model()
    embeddings = list(model.embed([text]))
    if embeddings and len(embeddings) > 0:
        return {"indices": embeddings[0].indices.tolist(), "values": embeddings[0].values.tolist()}
    return {"indices": [], "values": []}


def chunk_and_embed(text: str) -> list[tuple[str, list[float], dict]]:
    """Chunks text and returns list of (chunk_text, dense_vector, sparse_vector)."""
    chunks = chunk_text(text)
    return [(chunk, embed_text(chunk), embed_text_sparse(chunk)) for chunk in chunks]
