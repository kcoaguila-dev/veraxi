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

DEFAULT_RRF_K = 60


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


def merge_rank(
    vector_hits: list[VectorHit],
    graph_hits: list[GraphHit],
    k: int = DEFAULT_RRF_K,
    limit: int | None = None,
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

    if limit is not None:
        merged = merged[:limit]

    return merged