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


def embed_text(text: str) -> List[float]:
    """Mock embedder returning fixed 384-dim vectors based on text length."""
    # Using length to have slight variation but mostly mock
    val = (len(text) % 100) / 100.0
    return [val] * 384


def chunk_and_embed(text: str) -> List[Tuple[str, List[float]]]:
    """Chunks text and returns list of (chunk_text, embedding_vector)."""
    chunks = chunk_text(text)
    return [(chunk, embed_text(chunk)) for chunk in chunks]
