"""Tests for backend/retrieval/merge_rank.py.

Pure logic, fake data, no database connection - per AGENTS.md testing
expectations, this covers every change to merge_rank.py.
"""

from backend.retrieval.merge_rank import VectorHit, GraphHit, merge_rank, DEFAULT_RRF_K


def test_empty_inputs_return_empty_list():
    assert merge_rank([], []) == []


def test_vector_only_preserves_rank_order():
    hits = [
        VectorHit(id="a", score=0.9, payload={"text": "a"}),
        VectorHit(id="b", score=0.5, payload={"text": "b"}),
        VectorHit(id="c", score=0.1, payload={"text": "c"}),
    ]
    result = merge_rank(hits, [])

    assert [r.id for r in result] == ["a", "b", "c"]
    assert all(r.sources == ["vector"] for r in result)


def test_graph_only_preserves_rank_order():
    hits = [
        GraphHit(id="x", payload={"name": "x"}),
        GraphHit(id="y", payload={"name": "y"}),
    ]
    result = merge_rank([], hits)

    assert [r.id for r in result] == ["x", "y"]
    assert all(r.sources == ["graph"] for r in result)


def test_item_ranked_first_in_both_sources_wins_overall():
    # "a" is rank 1 in both lists, so it should out-fuse "z", which is
    # rank 1 in only one list.
    vector_hits = [
        VectorHit(id="a", score=0.99, payload={}),
        VectorHit(id="z", score=0.98, payload={}),
    ]
    graph_hits = [
        GraphHit(id="a", payload={}),
        GraphHit(id="q", payload={}),
    ]

    result = merge_rank(vector_hits, graph_hits)

    assert result[0].id == "a"
    assert result[0].sources == ["graph", "vector"]


def test_overlapping_id_score_is_sum_of_both_rankings():
    vector_hits = [VectorHit(id="shared", score=1.0, payload={})]
    graph_hits = [GraphHit(id="shared", payload={})]

    result = merge_rank(vector_hits, graph_hits, k=DEFAULT_RRF_K)

    expected = 1.0 / (DEFAULT_RRF_K + 1) + 1.0 / (DEFAULT_RRF_K + 1)
    assert len(result) == 1
    assert result[0].fused_score == expected
    assert result[0].sources == ["graph", "vector"]


def test_payload_from_first_source_seen_is_kept():
    # Vector is accumulated before graph, so vector's payload should win
    # when the same id appears in both with differing payloads.
    vector_hits = [VectorHit(id="dup", score=0.5, payload={"origin": "vector"})]
    graph_hits = [GraphHit(id="dup", payload={"origin": "graph"})]

    result = merge_rank(vector_hits, graph_hits)

    assert result[0].payload == {"origin": "vector"}


def test_limit_caps_result_count():
    vector_hits = [
        VectorHit(id="a", score=0.9, payload={}),
        VectorHit(id="b", score=0.8, payload={}),
        VectorHit(id="c", score=0.7, payload={}),
    ]

    result = merge_rank(vector_hits, [], limit=2)

    assert len(result) == 2
    assert [r.id for r in result] == ["a", "b"]


def test_different_k_changes_fusion_but_not_order_for_single_source():
    hits = [
        VectorHit(id="a", score=0.9, payload={}),
        VectorHit(id="b", score=0.8, payload={}),
    ]

    low_k = merge_rank(hits, [], k=1)
    high_k = merge_rank(hits, [], k=1000)

    # Order is unaffected by k for a single-source ranking.
    assert [r.id for r in low_k] == [r.id for r in high_k] == ["a", "b"]
    # But the actual fused scores differ since k changes the damping.
    assert low_k[0].fused_score != high_k[0].fused_score
