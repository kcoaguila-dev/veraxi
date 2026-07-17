from typing import List, Tuple


def chunk_text(text: str, chunk_size: int = 200, overlap: int = 50) -> List[str]:
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


def embed_text(text: str) -> List[float]:
    """Embed text using local sentence-transformers model."""
    if not text:
        return [0.0] * 384
    
    model = get_embedding_model()
    # model.encode returns a numpy array, convert to list of floats
    embedding = model.encode(text)
    return embedding.tolist()


def chunk_and_embed(text: str) -> List[Tuple[str, List[float]]]:
    """Chunks text and returns list of (chunk_text, embedding_vector)."""
    chunks = chunk_text(text)
    return [(chunk, embed_text(chunk)) for chunk in chunks]
