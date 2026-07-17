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
    args, kwargs = mock_client.execute_read.call_args
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
    args, kwargs = mock_client.execute_read.call_args
    assert "limit" in kwargs["parameters"]
    assert kwargs["parameters"]["limit"] == 5

    # Assert result structure
    assert len(result) == 2
    assert result[0]["id"] == "id1"
    assert result[0]["degree"] == 5
