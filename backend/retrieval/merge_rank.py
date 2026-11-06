"""backend/retrieval/merge_rank.py

Combines ranked results from Neo4j (graph traversal) and Qdrant (vector
search) into a single fused ranking using Reciprocal Rank Fusion (RRF).

RRF fuses rankings using only rank *position*, not raw scores - which
matters here because graph distance/relevance and cosine similarity are
not on the same scale and are not directly comparable. This is the single
place graph + vector results are combined (see AGENTS.md); don't duplicate
merge/ranking logic elsewhere.
"""

from dataclasses import dataclass, field
import logging
import threading

logger = logging.getLogger(__name__)

DEFAULT_RRF_K = 60

_CROSS_ENCODER_LOCK = threading.Lock()
_CROSS_ENCODER_CACHE: dict[tuple[str, int], object] = {}


def _get_cross_encoder(model_name: str, threads: int = 2):
    key = (model_name, threads)
    if key in _CROSS_ENCODER_CACHE:
        return _CROSS_ENCODER_CACHE[key]

    with _CROSS_ENCODER_LOCK:
        if key in _CROSS_ENCODER_CACHE:
            return _CROSS_ENCODER_CACHE[key]

        from fastembed.rerank.cross_encoder import TextCrossEncoder

        encoder = TextCrossEncoder(model_name=model_name, threads=threads)
        if len(_CROSS_ENCODER_CACHE) >= 4:
            oldest_key = next(iter(_CROSS_ENCODER_CACHE))
            del _CROSS_ENCODER_CACHE[oldest_key]

        _CROSS_ENCODER_CACHE[key] = encoder
        return encoder

_get_cross_encoder.cache_clear = _CROSS_ENCODER_CACHE.clear


@dataclass
class VectorHit:
    """A single result from Qdrant, ordered best-first by the caller."""

    id: str
    score: float
    payload: dict = field(default_factory=dict)


@dataclass
class GraphHit:
    """A single result from Neo4j, ordered best-first by the caller."""

    id: str
    payload: dict = field(default_factory=dict)


@dataclass
class MergedResult:
    """A fused result combining evidence from one or both sources."""

    id: str
    fused_score: float
    sources: list[str]
    payload: dict


def _is_near_duplicate(text_a: str, text_b: str, threshold: float = 0.75) -> bool:
    """Check if two texts share high token overlap (Jaccard similarity)."""
    words_a = set(text_a.lower().split())
    words_b = set(text_b.lower().split())
    if len(words_a) < 6 or len(words_b) < 6:
        return False
    intersection = len(words_a & words_b)
    union = len(words_a | words_b)
    return (intersection / union) >= threshold


def _format_reranker_document(item: MergedResult) -> str:
    """Format payload content into text representation for cross-encoder reranking.
    Enriches pure graph hits with structured entity and relationship metadata."""
    if not isinstance(item.payload, dict):
        return ""
    text = item.payload.get("text")
    if text and isinstance(text, str):
        return text
    parts = []
    name = item.payload.get("name") or item.payload.get("title")
    if name:
        parts.append(str(name))
    labels = item.payload.get("labels")
    if labels and isinstance(labels, list):
        parts.append(f"({', '.join(str(lbl) for lbl in labels)})")
    rel_type = item.payload.get("relation_type")
    if rel_type:
        parts.append(f"relation: {rel_type}")
    return " ".join(parts) if parts else ""


def _suppress_near_duplicates(
    merged: list[MergedResult], candidate_cap: int, threshold: float = 0.75
) -> list[MergedResult]:
    """Retrieval-time near-duplicate suppression (MMR / Diversity filter)."""
    deduped: list[MergedResult] = []
    for item in merged:
        text = item.payload.get("text", "") if isinstance(item.payload, dict) else ""
        if text and any(
            _is_near_duplicate(
                text,
                d.payload.get("text", "") if isinstance(d.payload, dict) else "",
                threshold=threshold,
            )
            for d in deduped
        ):
            continue
        deduped.append(item)
        if len(deduped) >= candidate_cap:
            break
    return deduped


def _rerank_with_cross_encoder(
    candidates: list[MergedResult], query_text: str, k: int = DEFAULT_RRF_K
) -> list[MergedResult]:
    """Reranks candidates using ONNX cross-encoder model and blends as an RRF rank leg."""
    import math
    import sentry_sdk

    from backend.config import get_config

    try:
        cfg = get_config()
        model_name = getattr(
            cfg, "reranker_model_name", "Xenova/ms-marco-MiniLM-L-6-v2"
        )
        threads = getattr(cfg, "embedding_threads", 2)
        encoder = _get_cross_encoder(model_name, threads=threads)

        docs = [_format_reranker_document(item) for item in candidates]

        with _CROSS_ENCODER_LOCK:
            ce_scores = list(encoder.rerank(query=query_text, documents=docs))

        ranked_indices = sorted(
            range(len(candidates)),
            key=lambda idx: float(ce_scores[idx]),
            reverse=True,
        )

        new_scores = []
        for ce_rank, orig_idx in enumerate(ranked_indices, start=1):
            item = candidates[orig_idx]
            try:
                raw_val = float(ce_scores[orig_idx])
                clamped_val = max(-50.0, min(50.0, raw_val))
                sigmoid_val = 1.0 / (1.0 + math.exp(-clamped_val))
            except Exception:
                sigmoid_val = 0.5

            new_fused_score = item.fused_score + (1.0 / (k + ce_rank)) + (1e-4 * sigmoid_val)
            new_scores.append((orig_idx, new_fused_score))

        for orig_idx, new_fused_score in new_scores:
            candidates[orig_idx].fused_score = new_fused_score

        candidates.sort(key=lambda r: r.fused_score, reverse=True)
    except Exception as err:
        sentry_sdk.capture_exception(err)
        logger.warning(
            "Cross-encoder reranking failed, falling back to RRF ranking: %s", err
        )
    return candidates


def merge_rank(
    vector_hits: list[VectorHit],
    graph_hits: list[GraphHit],
    k: int = DEFAULT_RRF_K,
    limit: int | None = None,
    query_text: str | None = None,
    rerank: bool | None = None,
) -> list[MergedResult]:
    """Fuse vector search results and graph traversal results via RRF.

    Both inputs must already be ordered best-to-worst by the caller
    (vector_hits by descending similarity score, graph_hits by traversal
    relevance/distance). Only rank position is used for fusion, so the two
    sources never need comparable score scales.

    An id present in both lists accumulates score from both rankings, so
    items corroborated by both graph and vector search are boosted above
    items found by only one source.

    Args:
        vector_hits: Qdrant results, ordered best-first.
        graph_hits: Neo4j results, ordered best-first.
        k: RRF damping constant. Higher k flattens the influence of exact
           rank position; 60 is the standard default used in the original
           RRF paper and widely reused since.
        limit: optional cap on the number of results returned.
        query_text: optional query string used for cross-encoder reranking.
        rerank: whether to apply ONNX cross-encoder reranking on top candidates.
                If None, defaults to config.reranker_enabled when query_text is given.

    Returns:
        Fused, deduplicated results sorted by fused_score descending.
    """
    fused_scores: dict[str, float] = {}
    payloads: dict[str, dict] = {}
    sources: dict[str, set[str]] = {}

    def _accumulate(hits, source_name: str) -> None:
        for rank, hit in enumerate(hits, start=1):
            fused_scores[hit.id] = fused_scores.get(hit.id, 0.0) + 1.0 / (k + rank)
            payloads.setdefault(hit.id, hit.payload)
            sources.setdefault(hit.id, set()).add(source_name)

    _accumulate(vector_hits, "vector")
    _accumulate(graph_hits, "graph")

    merged = [
        MergedResult(
            id=doc_id,
            fused_score=score,
            sources=sorted(sources[doc_id]),
            payload=payloads[doc_id],
        )
        for doc_id, score in fused_scores.items()
    ]
    merged.sort(key=lambda r: r.fused_score, reverse=True)

    # Retrieval-time near-duplicate suppression (MMR / Diversity filter)
    # Prevents near-identical chunks from different editions or repeating paragraphs
    # from crowding out distinct insights in the LLM context window.
    near_dup_thresh = 0.75
    try:
        from backend.config import get_config

        near_dup_thresh = getattr(get_config(), "near_duplicate_threshold", 0.75)
    except Exception:
        near_dup_thresh = 0.75

    candidate_cap = max(limit * 2 if limit else 20, 20)
    deduped = _suppress_near_duplicates(
        merged, candidate_cap=candidate_cap, threshold=near_dup_thresh
    )

    # Optional CPU-quantized Cross-Encoder reranking
    should_rerank = rerank
    if should_rerank is None and query_text and query_text.strip():
        try:
            from backend.config import get_config

            should_rerank = getattr(get_config(), "reranker_enabled", False)
        except Exception:
            should_rerank = False

    if should_rerank and query_text and query_text.strip() and deduped:
        deduped = _rerank_with_cross_encoder(deduped, query_text=query_text, k=k)

    if limit is not None:
        deduped = deduped[:limit]

    return deduped
