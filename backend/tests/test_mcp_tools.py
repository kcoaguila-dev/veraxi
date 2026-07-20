from unittest.mock import patch
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.ingestion.extract import validate_extraction
from backend.retrieval.merge_rank import VectorHit, GraphHit


@patch("backend.mcp_server.tools.search_vectors.get_config")
@patch("backend.mcp_server.tools.search_vectors.QdrantStorageClient")
def test_search_vectors_shape(mock_qdrant_class, mock_get_config):
    # Mock the search response
    mock_instance = mock_qdrant_class.from_config.return_value
    mock_instance.search.return_value = [
        {"id": "uuid-1", "score": 0.9, "payload": {"text": "chunk 1"}},
        {"id": "uuid-2", "score": 0.8, "payload": {"text": "chunk 2"}},
    ]

    hits = search_vectors("dummy query", limit=2)

    assert len(hits) == 2
    assert all(isinstance(hit, VectorHit) for hit in hits)
    assert hits[0].id == "uuid-1"
    assert hits[0].score == 0.9
    assert hits[0].payload == {"text": "chunk 1"}


@patch("backend.mcp_server.tools.query_graph.get_config")
@patch("backend.mcp_server.tools.query_graph.Neo4jStorageClient")
def test_query_graph_shape(mock_neo4j_class, mock_get_config):
    # Mock the execute_read response
    mock_instance = mock_neo4j_class.from_config.return_value
    mock_instance.execute_read.return_value = [
        {
            "id": "node-1",
            "qdrant_point_id": "uuid-1",
            "labels": ["Person"],
            "props": {"name": "Alice", "role": "Engineer"},
        },
        {
            "id": "node-2",
            "qdrant_point_id": "uuid-3",
            "labels": ["Concept"],
            "props": {"name": "AI"},
        },
    ]

    hits = query_graph("Alice", max_hops=1)

    assert len(hits) == 2
    assert all(isinstance(hit, GraphHit) for hit in hits)
    assert hits[0].id == "uuid-1"
    assert hits[0].payload["name"] == "Alice"
    assert "Person" in hits[0].payload["labels"]


def test_extraction_validation_rejects_malformed():
    malformed_entities = [
        {"type": "InvalidType", "name": "Bob"},  # Invalid type
        {"type": "Person"},  # Missing name
        {"type": "Person", "name": "Alice", "properties": {"role": "CEO"}},  # Valid
    ]
    malformed_relations = [
        {
            "from_entity": "Alice",
            "to_entity": "Bob",
            "type": "WORKS_AT",
        },  # Bob is invalid
        {
            "from_entity": "Alice",
            "to_entity": "Veraxi",
            "type": "WORKS_AT",
        },  # Veraxi is missing
        {
            "from_entity": "Alice",
            "to_entity": "Alice",
            "type": "INVALID_REL",
        },  # Invalid relation type
    ]

    valid_ents, valid_rels = validate_extraction(
        malformed_entities, malformed_relations
    )

    # Only Alice should be valid
    assert len(valid_ents) == 1
    assert valid_ents[0]["name"] == "Alice"

    # All relations should be rejected because one side or the type is invalid
    assert len(valid_rels) == 0


def test_extraction_validation_accepts_correct():
    entities = [
        {"type": "Person", "name": "Alice"},
        {"type": "Organization", "name": "Veraxi Corp"},
    ]
    relations = [
        {"from_entity": "Alice", "to_entity": "Veraxi Corp", "type": "WORKS_AT"}
    ]

    valid_ents, valid_rels = validate_extraction(entities, relations)

    assert len(valid_ents) == 2
    assert len(valid_rels) == 1
    assert valid_rels[0]["type"] == "WORKS_AT"


def test_extraction_validation_normalizes_nested_properties():
    """Test that nested properties are dropped/normalized for Neo4j compatibility."""
    entities = [
        {
            "type": "Person",
            "name": "Alice",
            "properties": {
                "role": "Engineer",  # Valid primitive
                "skills": ["Python", "Go"],  # Valid array of primitives
                "nested_dict": {"key": "value"},  # Invalid - nested dict
                "count": 42,  # Valid primitive
                "active": True,  # Valid primitive
                "mixed_array": ["text", {"nested": "object"}],  # Invalid - contains nested object
            },
        }
    ]
    relations = []

    valid_ents, valid_rels = validate_extraction(entities, relations)

    assert len(valid_ents) == 1
    props = valid_ents[0]["properties"]

    # Valid properties should be retained
    assert props["role"] == "Engineer"
    assert props["skills"] == ["Python", "Go"]
    assert props["count"] == 42
    assert props["active"] is True

    # Invalid properties should be dropped
    assert "nested_dict" not in props
    assert "mixed_array" not in props


from backend.mcp_server.tools.insert_graph import insert_graph_nodes
from backend.mcp_server.tools.insert_vector import insert_vectors

@patch("backend.mcp_server.tools.insert_graph.get_config")
@patch("backend.mcp_server.tools.insert_graph.Neo4jStorageClient")
def test_insert_graph_nodes_success(mock_neo4j_class, mock_get_config):
    mock_instance = mock_neo4j_class.from_config.return_value
    mock_instance.create_node.return_value = "node-id"

    nodes = [{"type": "Person", "name": "Alice"}]
    relations = []

    result = insert_graph_nodes(nodes, relations)

    assert result["status"] == "success"
    assert result["nodes_inserted"] == 1
    assert result["relations_inserted"] == 0
    mock_instance.create_node.assert_called_once()

@patch("backend.mcp_server.tools.insert_vector.get_config")
@patch("backend.mcp_server.tools.insert_vector.QdrantStorageClient")
def test_insert_vectors_success(mock_qdrant_class, mock_get_config):
    mock_instance = mock_qdrant_class.from_config.return_value
    mock_instance.insert_points.return_value = ["uuid-1", "uuid-2"]

    texts = ["chunk 1", "chunk 2"]

    result = insert_vectors(texts)

    assert result["status"] == "success"
    assert result["vectors_inserted"] == 2
    assert result["point_ids"] == ["uuid-1", "uuid-2"]
    mock_instance.insert_points.assert_called_once()
