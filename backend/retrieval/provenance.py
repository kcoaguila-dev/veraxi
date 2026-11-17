"""backend/retrieval/provenance.py

"Show me the path" provenance shaping for retrieval results.

This module only *formats* provenance that already exists on retrieval
results — it never invents it:

- ``legs`` is the subset of ``KNOWN_LEGS`` present in a result's
  ``sources`` list, exactly as recorded by ``merge_rank``. Note what
  that means in practice: the Qdrant hybrid search (dense MiniLM +
  sparse SPLADE, fused inside Qdrant by
  ``QdrantStorageClient.search_hybrid``) returns a single fused hit, so
  a per-hit dense-vs-sparse split does not exist anywhere in the
  pipeline. Hybrid hits are therefore honestly labelled with the single
  ``"vector"`` leg that ``merge_rank`` records; ``"sparse"`` is a known
  leg name (reserved for a future per-leg split) but is never emitted
  today.
- ``fused_score`` is passed through from ``MergedResult.fused_score``
  (the RRF + optional cross-encoder rerank score) when present. For
  lazy-graph dossier chunks it is the chunk's Qdrant hybrid score.
  Results without a score expose ``None``.
- ``graph_path`` is exposed only when the ``"graph"`` leg contributed
  *and* the payload carries a ``graph_path`` captured at the graph
  retrieval site (see ``tools/query_graph.py``, which records the
  ordered traversal path from parameterized Cypher). Each step is
  ``{"node": <node name>, "relation": <relation to the next node>}``;
  the final step's relation is ``None``. When no path was captured the
  field is ``None`` — a path is never reconstructed or fabricated from
  partial fields such as ``source_entity``/``relation_type`` alone.

This lives in the retrieval layer so both ``mcp_server`` response paths
and retrieval-internal producers (the lazy-graph dossier) can use it
without violating the backend dependency direction (retrieval must not
import ``mcp_server``). Merge/ranking logic itself stays solely in
``merge_rank.py``; nothing here re-ranks anything.
"""

from __future__ import annotations

from typing import Any

KNOWN_LEGS = ("vector", "sparse", "graph")


def _normalize_graph_path(raw_path: Any) -> list[dict[str, Any]] | None:
    """Validate a captured graph path, returning ordered steps or None.

    A path needs at least two node steps to describe a traversal; a
    malformed or single-node value is treated as absent rather than
    partially rendered.
    """
    if not isinstance(raw_path, list) or len(raw_path) < 2:
        return None
    steps: list[dict[str, Any]] = []
    for step in raw_path:
        if not isinstance(step, dict):
            return None
        node = step.get("node")
        if not isinstance(node, str) or not node.strip():
            return None
        relation = step.get("relation")
        if relation is not None and not isinstance(relation, str):
            return None
        steps.append({"node": node, "relation": relation})
    return steps


def build_graph_path(
    node_names: list[Any], relation_types: list[Any]
) -> list[dict[str, Any]] | None:
    """Assemble ordered provenance steps from a captured traversal.

    ``node_names`` are the traversal's nodes in order and
    ``relation_types[i]`` is the relation from node ``i`` to node
    ``i + 1``. Returns None when the capture is incomplete (fewer than
    two nodes, or a relation count that does not match the node count),
    so callers store no path rather than a partial one.
    """
    names = [n for n in node_names if isinstance(n, str) and n.strip()]
    if len(names) < 2 or len(names) != len(node_names):
        return None
    if len(relation_types) != len(names) - 1:
        return None
    relations = [r if isinstance(r, str) and r else None for r in relation_types]
    if any(r is None for r in relations):
        return None
    steps = [
        {"node": name, "relation": relations[idx] if idx < len(relations) else None}
        for idx, name in enumerate(names)
    ]
    return steps


def build_provenance(result: Any) -> dict[str, Any] | None:
    """Build the provenance dict for one retrieval result, or None.

    Accepts a ``MergedResult`` (attribute access), a serialized hit
    dict, or a lazy-graph dossier chunk dict. Returns None when the
    result carries no recognizable retrieval leg — e.g. telemetry/tool
    hits whose ``sources`` are display labels like "GitHub" — so
    non-retrieval results never gain fabricated provenance.
    """
    if isinstance(result, dict):
        sources = result.get("sources")
        payload = result.get("payload") if isinstance(result.get("payload"), dict) else {}
        fused_score = result.get("fused_score", result.get("score"))
        chunk_path = result.get("graph_path")
    else:
        sources = getattr(result, "sources", None)
        payload = getattr(result, "payload", None)
        if not isinstance(payload, dict):
            payload = {}
        fused_score = getattr(result, "fused_score", None)
        if fused_score is None:
            fused_score = getattr(result, "score", None)
        chunk_path = None

    if not isinstance(sources, list):
        sources = []
    legs = [leg for leg in KNOWN_LEGS if leg in sources]
    if not legs and isinstance(result, dict) and "score" in result:
        # Lazy-graph dossier chunk: produced by Qdrant hybrid search and
        # shaped without a `sources` list. Its only honest leg is the
        # hybrid "vector" leg; linked Neo4j entities are anchors on the
        # chunk, not a graph traversal contribution, and there is no
        # ordered path to show.
        legs = ["vector"]
    if not legs:
        return None

    graph_path = None
    if "graph" in legs:
        graph_path = _normalize_graph_path(payload.get("graph_path", chunk_path))

    return {
        "legs": legs,
        "fused_score": float(fused_score)
        if isinstance(fused_score, (int, float)) and not isinstance(fused_score, bool)
        else None,
        "graph_path": graph_path,
    }
