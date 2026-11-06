"""Tests for backend/retrieval/merge_rank.py.

Pure logic, fake data, no database connection - per AGENTS.md testing
expectations, this covers every change to merge_rank.py.
"""

from backend.retrieval.merge_rank import DEFAULT_RRF_K, GraphHit, VectorHit, merge_rank


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


def test_near_duplicate_chunks_are_suppressed():
    # Hit "dup1" and "dup2" share almost identical text (from two editions or boilerplate)
    # "unique3" has distinct text. "dup2" should be suppressed in favor of "unique3".
    text_edition_4 = "Financial shenanigans and accounting irregularities involve deceptive revenue recognition methods."
    text_edition_2 = "Financial shenanigans and accounting irregularities involve deceptive revenue recognition practices."
    text_distinct = "David Einhorn investigated Allied Capital for valuation fraud and aggressive debt structures."

    vector_hits = [
        VectorHit(id="dup1", score=0.95, payload={"text": text_edition_4}),
        VectorHit(id="dup2", score=0.90, payload={"text": text_edition_2}),
        VectorHit(id="unique3", score=0.85, payload={"text": text_distinct}),
    ]

    result = merge_rank(vector_hits, [], limit=2)

    # dup2 must be dropped because it is a near-duplicate of dup1 (>85% word overlap)
    # unique3 must be retained in the top 2
    assert len(result) == 2
    assert [r.id for r in result] == ["dup1", "unique3"]


def test_merge_rank_cross_encoder_rerank():
    from unittest.mock import MagicMock, patch

    vector_hits = [
        VectorHit(id="hit1", score=0.9, payload={"text": "Generic financial overview without specifics."}),
        VectorHit(id="hit2", score=0.8, payload={"text": "Allied Capital valuation fraud analysis by Greenlight."}),
    ]

    mock_encoder = MagicMock()
    # Cross-encoder scores hit2 much higher for query "Allied Capital fraud"
    mock_encoder.rerank.return_value = [0.1, 0.95]

    with patch("backend.retrieval.merge_rank._get_cross_encoder", return_value=mock_encoder):
        result = merge_rank(
            vector_hits,
            [],
            query_text="Allied Capital fraud",
            rerank=True,
        )

        assert len(result) == 2
        # hit2 should be elevated to position 1 due to high cross-encoder relevance
        assert result[0].id == "hit2"
        assert result[1].id == "hit1"
        mock_encoder.rerank.assert_called_once()


def test_cross_encoder_preserves_dual_source_corroboration():
    from unittest.mock import MagicMock, patch

    # "shared" is corroborated by both vector and graph.
    # "single" is vector-only, but gets top score from cross-encoder.
    vector_hits = [
        VectorHit(id="shared", score=0.9, payload={"text": "Evidence corroborated by both graph and text."}),
        VectorHit(id="single", score=0.85, payload={"text": "Single vector evidence with high cross encoder rank."}),
    ]
    graph_hits = [
        GraphHit(id="shared", payload={"name": "shared_entity"}),
    ]

    mock_encoder = MagicMock()
    # CE ranks "single" #1 (0.95) and "shared" #2 (0.2)
    mock_encoder.rerank.return_value = [0.2, 0.95]

    with patch("backend.retrieval.merge_rank._get_cross_encoder", return_value=mock_encoder):
        result = merge_rank(
            vector_hits,
            graph_hits,
            query_text="Evidence query",
            rerank=True,
        )

        assert len(result) == 2
        # "shared" has 3 rank inputs (vector #1, graph #1, CE #2) so it retains top position
        # over "single" which only has 2 rank inputs (vector #2, CE #1)
        assert result[0].id == "shared"
        assert result[1].id == "single"


def test_merge_rank_near_duplicate_custom_threshold():
    from unittest.mock import MagicMock, patch

    text_a = "Financial irregularities involve deceptive revenue recognition methods."
    text_b = "Financial irregularities involve deceptive revenue recognition practices."

    vector_hits = [
        VectorHit(id="hit_a", score=0.95, payload={"text": text_a}),
        VectorHit(id="hit_b", score=0.90, payload={"text": text_b}),
    ]

    mock_cfg = MagicMock()
    # With threshold 1.0, near-duplicates are NOT suppressed
    mock_cfg.near_duplicate_threshold = 1.0
    mock_cfg.reranker_enabled = False

    with patch("backend.config.get_config", return_value=mock_cfg):
        result = merge_rank(vector_hits, [], limit=2)
        assert len(result) == 2
        assert [r.id for r in result] == ["hit_a", "hit_b"]



def test_cross_encoder_failure_reports_to_sentry_and_falls_back():
    from unittest.mock import MagicMock, patch

    vector_hits = [
        VectorHit(id="hit1", score=0.9, payload={"text": "Chunk text 1"}),
        VectorHit(id="hit2", score=0.8, payload={"text": "Chunk text 2"}),
    ]

    mock_encoder = MagicMock()
    mock_encoder.rerank.side_effect = RuntimeError("ONNX session error")

    with (
        patch("backend.retrieval.merge_rank._get_cross_encoder", return_value=mock_encoder),
        patch("sentry_sdk.capture_exception") as mock_sentry,
    ):
        result = merge_rank(
            vector_hits,
            [],
            query_text="Sample query",
            rerank=True,
        )

        assert len(result) == 2
        # Falls back cleanly to RRF order
        assert [r.id for r in result] == ["hit1", "hit2"]
        mock_sentry.assert_called_once()


def test_format_reranker_document_enriches_graph_hit():
    from backend.retrieval.merge_rank import MergedResult, _format_reranker_document

    # Text payload returns text directly
    doc_with_text = MergedResult(
        id="1", fused_score=0.1, sources=["vector"], payload={"text": "Sample text"}
    )
    assert _format_reranker_document(doc_with_text) == "Sample text"

    # Pure graph hit with name, labels, and relation_type
    doc_graph = MergedResult(
        id="2",
        fused_score=0.1,
        sources=["graph"],
        payload={
            "name": "Acme Corp",
            "labels": ["Organization", "Company"],
            "relation_type": "INVESTED_IN",
        },
    )
    doc_str = _format_reranker_document(doc_graph)
    assert "Acme Corp" in doc_str
    assert "Organization, Company" in doc_str
    assert "relation: INVESTED_IN" in doc_str

