"""Tests for backend/retrieval/provenance.py ("show me the path").

Pure logic, constructed results only — no database. Covers the honest
data contract: legs come from MergedResult.sources as recorded by
merge_rank, fused_score passes through, and a graph path is exposed
only when a graph leg contributed AND a captured path exists in the
payload. Nothing is fabricated.
"""

from backend.retrieval.merge_rank import GraphHit, MergedResult, VectorHit
from backend.retrieval.provenance import build_graph_path, build_provenance

GRAPH_PATH = [
    {"node": "Acme Corp", "relation": "ACQUIRED"},
    {"node": "Beta LLC", "relation": "SUPPLIES"},
    {"node": "Gamma Inc", "relation": None},
]


def _merged(sources, payload=None, fused_score=0.032):
    return MergedResult(
        id="doc-1",
        fused_score=fused_score,
        sources=sources,
        payload=payload or {},
    )


# --- legs -----------------------------------------------------------------


def test_vector_only_result_exposes_vector_leg_and_score():
    prov = build_provenance(_merged(["vector"]))

    assert prov == {"legs": ["vector"], "fused_score": 0.032, "graph_path": None}


def test_graph_and_vector_legs_exposed_in_known_order():
    prov = build_provenance(_merged(["vector", "graph"]))

    assert prov["legs"] == ["vector", "graph"]


def test_hybrid_vector_leg_is_not_split_into_sparse():
    # Qdrant hybrid search fuses dense + sparse internally and returns a
    # single hit, so merge_rank records only "vector". Provenance must
    # not claim a distinct sparse leg that cannot be attributed per hit.
    prov = build_provenance(_merged(["vector"]))

    assert "sparse" not in prov["legs"]


def test_telemetry_style_sources_produce_no_provenance():
    class TelemetryHit:
        def __init__(self):
            self.sources = ["GitHub"]
            self.payload = {"content": "telemetry"}

    assert build_provenance(TelemetryHit()) is None


def test_result_without_sources_produces_no_provenance():
    assert build_provenance(VectorHit(id="v", score=0.5, payload={})) is None
    assert build_provenance(GraphHit(id="g", payload={})) is None


# --- fused score ------------------------------------------------------------


def test_fused_score_passes_through_exactly():
    prov = build_provenance(_merged(["graph"], fused_score=0.123456))

    assert prov["fused_score"] == 0.123456


def test_missing_score_is_none_not_zero():
    prov = build_provenance({"sources": ["vector"], "payload": {}})

    assert prov["fused_score"] is None


# --- graph path -------------------------------------------------------------


def test_graph_path_exposed_in_order_when_graph_leg_and_path_present():
    prov = build_provenance(_merged(["graph"], payload={"graph_path": GRAPH_PATH}))

    assert prov["graph_path"] == GRAPH_PATH
    assert [s["node"] for s in prov["graph_path"]] == [
        "Acme Corp",
        "Beta LLC",
        "Gamma Inc",
    ]
    assert [s["relation"] for s in prov["graph_path"]] == [
        "ACQUIRED",
        "SUPPLIES",
        None,
    ]


def test_graph_leg_without_captured_path_has_no_fabricated_path():
    # source_entity / relation_type alone describe only the last hop;
    # they must not be inflated into a full path.
    payload = {"source_entity": "Acme Corp", "relation_type": "ACQUIRED"}
    prov = build_provenance(_merged(["graph"], payload=payload))

    assert prov["legs"] == ["graph"]
    assert prov["graph_path"] is None


def test_path_in_payload_is_ignored_without_graph_leg():
    prov = build_provenance(_merged(["vector"], payload={"graph_path": GRAPH_PATH}))

    assert prov["graph_path"] is None


def test_malformed_path_is_treated_as_absent():
    bad_paths = [
        [{"node": "Only Node", "relation": None}],
        [{"node": "A", "relation": "R"}, {"relation": None}],
        [{"node": "A", "relation": "R"}, {"node": "B", "relation": 42}],
        "not-a-list",
    ]
    for bad in bad_paths:
        prov = build_provenance(_merged(["graph"], payload={"graph_path": bad}))
        assert prov["graph_path"] is None, bad


# --- build_graph_path (capture assembly) ------------------------------------


def test_build_graph_path_assembles_ordered_steps():
    steps = build_graph_path(
        ["Acme Corp", "Beta LLC", "Gamma Inc"], ["ACQUIRED", "SUPPLIES"]
    )

    assert steps == GRAPH_PATH


def test_build_graph_path_rejects_incomplete_capture():
    assert build_graph_path(["Only"], []) is None
    assert build_graph_path(["A", "B", "C"], ["ONLY_ONE"]) is None
    assert build_graph_path(["A", "B"], [None]) is None
    assert build_graph_path(["A", ""], ["R"]) is None
    assert build_graph_path([], []) is None


# --- dossier chunks ---------------------------------------------------------


def test_dossier_chunk_gets_vector_leg_and_hybrid_score_no_graph_path():
    chunk = {
        "point_id": "chunk-1",
        "score": 0.87,
        "text": "evidence text",
        "title": "Doc",
        "metadata": {},
        "linked_entities": [{"name": "Acme Corp", "type": "Organization"}],
    }

    prov = build_provenance(chunk)

    # Linked entities are anchors, not a traversal: no graph leg, no path.
    assert prov == {"legs": ["vector"], "fused_score": 0.87, "graph_path": None}


# --- serialized dict form ---------------------------------------------------


def test_serialized_merged_result_dict_keeps_provenance():
    serialized = {
        "id": "doc-1",
        "fused_score": 0.05,
        "sources": ["graph", "vector"],
        "payload": {"graph_path": GRAPH_PATH},
    }

    prov = build_provenance(serialized)

    assert prov["legs"] == ["vector", "graph"]
    assert prov["fused_score"] == 0.05
    assert prov["graph_path"] == GRAPH_PATH
