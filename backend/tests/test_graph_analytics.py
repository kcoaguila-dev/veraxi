from unittest.mock import MagicMock

from backend.retrieval.graph_analytics import (
    get_community_detection,
    get_node_degree_centrality,
)


def test_get_community_detection_calls_client():
    mock_client = MagicMock()
    mock_client.execute_read.return_value = [
        {"community": "Person", "size": 2, "members": ["id1", "id2"]},
        {"community": "Organization", "size": 1, "members": ["id3"]},
    ]

    result = get_community_detection(mock_client, min_community_size=1)

    # Assert query was executed
    mock_client.execute_read.assert_called_once()
    _args, kwargs = mock_client.execute_read.call_args
    assert "min_community_size" in kwargs["parameters"]
    assert kwargs["parameters"]["min_community_size"] == 1

    # Assert result structure
    assert len(result) == 2
    assert result[0]["community"] == "Person"
    assert result[0]["size"] == 2


def test_get_node_degree_centrality_calls_client():
    mock_client = MagicMock()
    mock_client.execute_read.return_value = [
        {"id": "id1", "label": "Person", "degree": 5},
        {"id": "id2", "label": "Organization", "degree": 2},
    ]

    result = get_node_degree_centrality(mock_client, limit=5)

    # Assert query was executed
    mock_client.execute_read.assert_called_once()
    _args, kwargs = mock_client.execute_read.call_args
    assert "limit" in kwargs["parameters"]
    assert kwargs["parameters"]["limit"] == 5

    # Assert result structure
    assert len(result) == 2
    assert result[0]["id"] == "id1"
    assert result[0]["degree"] == 5


# ---------------------------------------------------------------------------
# WP3: pure-Python fallback communities (no label grouping)
# ---------------------------------------------------------------------------

from backend.retrieval.graph_analytics import detect_communities


def _nodes(*specs):
    return [{"name": name, "label": label} for name, label in specs]


def test_detect_communities_clusters_by_edges_not_labels():
    nodes = _nodes(
        ("Alice", "Person"), ("Bob", "Person"), ("Carol", "Person"),
        ("Dave", "Person"), ("Eve", "Person"), ("Frank", "Person"),
        ("UnlinkedChunk_ab12", "Chunk"), ("Lonely", "Person"),
    )
    edges = [
        ("Alice", "Bob"), ("Bob", "Carol"), ("Alice", "Carol"),
        ("Dave", "Eve"), ("Eve", "Frank"), ("Dave", "Frank"),
        ("Alice", "UnlinkedChunk_ab12"),
    ]
    rows = detect_communities(nodes, edges)
    member_sets = {frozenset(r["members"]) for r in rows}
    assert frozenset({"Alice", "Bob", "Carol"}) in member_sets
    assert frozenset({"Dave", "Eve", "Frank"}) in member_sets
    all_members = {m for r in rows for m in r["members"]}
    assert "UnlinkedChunk_ab12" not in all_members
    assert "Lonely" not in all_members  # degree-0 excluded
    # Communities are edge clusters, not the single "Person" label.
    assert len(rows) == 2


def test_fallback_used_when_gds_unavailable():
    mock_client = MagicMock()

    def fake_read(query, parameters=None):
        if "gds.louvain" in query:
            raise RuntimeError("no GDS")
        if "RETURN n.name AS name" in query:
            return [
                {"name": "Alice", "label": "Person"},
                {"name": "Bob", "label": "Person"},
                {"name": "UnlinkedChunk_ab12", "label": "Chunk"},
            ]
        return [{"source": "Alice", "target": "Bob"}]

    mock_client.execute_read.side_effect = fake_read
    result = get_community_detection(mock_client, min_community_size=1, tenant_id="t")
    assert len(result) == 1
    assert result[0]["members"] == ["Alice", "Bob"]
