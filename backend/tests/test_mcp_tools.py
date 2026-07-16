from unittest.mock import patch
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.mcp_server.tools.ingest_data import ingest_data
from backend.ingestion.extract import validate_extraction
from backend.retrieval.merge_rank import VectorHit, GraphHit

@patch("backend.mcp_server.tools.search_vectors.get_config")
@patch("backend.mcp_server.tools.search_vectors.QdrantStorageClient")
def test_search_vectors_shape(mock_qdrant_class, mock_get_config):
    # Mock the search response
    mock_instance = mock_qdrant_class.return_value
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
    mock_instance = mock_neo4j_class.return_value
    mock_instance.execute_read.return_value = [
        {"id": "node-1", "qdrant_point_id": "uuid-1", "labels": ["Person"], "props": {"name": "Alice", "role": "Engineer"}},
        {"id": "node-2", "qdrant_point_id": "uuid-3", "labels": ["Concept"], "props": {"name": "AI"}},
    ]

    hits = query_graph("Alice", max_hops=1)

    assert len(hits) == 2
    assert all(isinstance(hit, GraphHit) for hit in hits)
    assert hits[0].id == "uuid-1"
    assert hits[0].payload["name"] == "Alice"
    assert "Person" in hits[0].payload["labels"]

def test_extraction_validation_rejects_malformed():
    malformed_entities = [
        {"type": "InvalidType", "name": "Bob"}, # Invalid type
        {"type": "Person"}, # Missing name
        {"type": "Person", "name": "Alice", "properties": {"role": "CEO"}}, # Valid
    ]
    malformed_relations = [
        {"from_entity": "Alice", "to_entity": "Bob", "type": "WORKS_AT"}, # Bob is invalid
        {"from_entity": "Alice", "to_entity": "Veraxi", "type": "WORKS_AT"}, # Veraxi is missing
        {"from_entity": "Alice", "to_entity": "Alice", "type": "INVALID_REL"} # Invalid relation type
    ]

    valid_ents, valid_rels = validate_extraction(malformed_entities, malformed_relations)

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

@patch("backend.mcp_server.tools.ingest_data.run_ingestion")
@patch("backend.mcp_server.tools.ingest_data.get_config")
def test_ingest_data_shape(mock_get_config, mock_run_ingestion):
    # Mock the ingestion response
    mock_run_ingestion.return_value = {
        "nodes_inserted": 5,
        "vectors_inserted": 5
    }

    result = ingest_data("dummy text")

    assert "Successfully ingested data." in result
    assert "Inserted 5 graph nodes and 5 vector embeddings." in result
    mock_run_ingestion.assert_called_once()

@patch("backend.mcp_server.tools.ingest_data.run_ingestion")
@patch("backend.mcp_server.tools.ingest_data.get_config")
def test_ingest_data_passes_tenant_id(mock_get_config, mock_run_ingestion):
    mock_config = mock_get_config.return_value
    mock_run_ingestion.return_value = {"nodes_inserted": 1, "vectors_inserted": 1}

    ingest_data("dummy text", tenant_id="tenant-42")

    mock_run_ingestion.assert_called_once_with(
        mock_config, "dummy text", tenant_id="tenant-42"
    )

@patch("backend.mcp_server.tools.ingest_data.run_ingestion")
@patch("backend.mcp_server.tools.ingest_data.get_config")
def test_ingest_data_defaults_missing_counts_to_zero(mock_get_config, mock_run_ingestion):
    # Ingestion pipeline may return a result missing the expected keys
    mock_run_ingestion.return_value = {}

    result = ingest_data("dummy text")

    assert "Inserted 0 graph nodes and 0 vector embeddings." in result

@patch("backend.mcp_server.tools.ingest_data.run_ingestion")
@patch("backend.mcp_server.tools.ingest_data.get_config")
def test_ingest_data_returns_error_message_on_exception(mock_get_config, mock_run_ingestion):
    mock_run_ingestion.side_effect = RuntimeError("pipeline failure")

    result = ingest_data("dummy text")

    assert "Error executing ingestion tool" in result
    assert "pipeline failure" in result
