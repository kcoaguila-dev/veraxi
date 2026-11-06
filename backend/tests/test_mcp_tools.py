from unittest.mock import patch

from backend.ingestion.extract import validate_extraction
from backend.mcp_server.tools.query_graph import query_graph
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.retrieval.merge_rank import GraphHit, VectorHit


@patch("backend.mcp_server.tools.search_vectors.get_config")
@patch("backend.mcp_server.tools.search_vectors.QdrantStorageClient")
def test_search_vectors_shape(mock_qdrant_class, mock_get_config):
    # Mock the search response
    mock_instance = mock_qdrant_class.from_config.return_value
    mock_instance.search_hybrid.return_value = [
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

    schema = {
        "entities": ["Person", "Organization"],
        "relations": {"Person": {"Organization": ["WORKS_AT"]}},
    }
    valid_ents, valid_rels = validate_extraction(
        malformed_entities, malformed_relations, schema
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

    schema = {
        "entities": ["Person", "Organization"],
        "relations": {"Person": {"Organization": ["WORKS_AT"]}},
    }
    valid_ents, valid_rels = validate_extraction(entities, relations, schema)

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
                "mixed_array": [
                    "text",
                    {"nested": "object"},
                ],  # Invalid - contains nested object
            },
        }
    ]
    relations = []

    schema = {
        "entities": ["Person", "Organization"],
        "relations": {"Person": {"Organization": ["WORKS_AT"]}},
    }
    valid_ents, _valid_rels = validate_extraction(entities, relations, schema)

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


from backend.mcp_server.tools.insert_vector import insert_vectors
from backend.storage.graph_operations import insert_graph_nodes


@patch("backend.storage.graph_operations.get_config")
@patch("backend.storage.graph_operations.Neo4jStorageClient")
def test_insert_graph_nodes_success(mock_neo4j_class, mock_get_config):
    mock_instance = mock_neo4j_class.from_config.return_value
    mock_instance.create_node.return_value = "node-id"
    mock_instance.execute_read.return_value = []

    nodes = [{"type": "Person", "name": "Alice"}]
    relations = []

    result = insert_graph_nodes(nodes, relations)

    assert result["status"] == "success"
    assert result["nodes_new"] == 1
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


def test_mcp_schema_demarcation_and_optional_entity():
    from backend.mcp_server.handlers.tool_registry import (
        REGISTERED_TOOLS,
        _handle_merge_rank,
    )
    from backend.retrieval.merge_rank import VectorHit

    tools_by_name = {t.name: t for t in REGISTERED_TOOLS}

    # Verify tool schema demarcations
    assert "[DEFAULT - Fast" in tools_by_name["mcp_merge_rank"].description
    assert "[HEAVY - Long Running" in tools_by_name["mcp_agentic_debate"].description
    assert "[FAST - Vector Only" in tools_by_name["mcp_search_vectors"].description
    assert "[FAST - Graph Only" in tools_by_name["mcp_query_graph"].description
    assert "[DEEP WEB CRAWL & RAG" in tools_by_name["mcp_ephemeral_web_rag"].description

    # Verify entity_name is optional in mcp_merge_rank schema and rerank is configurable
    merge_rank_schema = tools_by_name["mcp_merge_rank"].input_schema
    assert merge_rank_schema["required"] == ["query_text"]
    assert "entity_name" not in merge_rank_schema["required"]
    assert "rerank" in merge_rank_schema["properties"]
    assert merge_rank_schema["properties"]["rerank"]["type"] == "boolean"

    # Verify _handle_merge_rank works cleanly without entity_name
    with (
        patch("backend.mcp_server.handlers.tool_registry.search_vectors") as mock_sv,
        patch("backend.mcp_server.handlers.tool_registry.query_graph") as mock_qg,
    ):
        mock_sv.return_value = [
            VectorHit(
                id="chunk-1",
                score=0.9,
                payload={"text": "Auth docs", "title": "AuthModule"},
            )
        ]
        mock_qg.return_value = []

        # Call with only query_text
        res = _handle_merge_rank({"query_text": "OAuth flow"}, tenant_id="test_tenant")
        assert len(res) == 1
        assert "chunk-1" in res[0].text
        # Fallback seeded candidate from vector hit title
        mock_qg.assert_called_once_with(
            entity_name="AuthModule",
            max_hops=2,
            tenant_id="test_tenant",
        )


def test_fact_check_tool_registration_and_proof_formatting():
    from backend.mcp_server.handlers.tool_registry import (
        REGISTERED_TOOLS,
        _format_mcp_proof_card,
        _handle_fact_check,
    )
    from backend.retrieval.merge_rank import VectorHit

    tools_by_name = {t.name: t for t in REGISTERED_TOOLS}
    assert "mcp_fact_check" in tools_by_name
    assert "[FACT-CHECK PROOF ENGINE]" in tools_by_name["mcp_fact_check"].description

    # Test _format_mcp_proof_card
    sample_hits = [
        VectorHit(
            id="hit-1",
            score=0.95,
            payload={
                "text": "The company reported revenue of $500 million in Q4 2023.",
                "source": "Annual Report.pdf",
                "page_number": 42,
            },
        )
    ]
    card = _format_mcp_proof_card("company revenue Q4 2023", sample_hits)
    assert "### 🛡️ Grounded Evidence Citations (Veraxi Hybrid GraphRAG)" in card
    assert "Annual Report.pdf" in card
    assert "Page 42" in card
    assert "revenue of $500 million" in card

    # Test _handle_fact_check with mocked run_check
    with patch("backend.cli.check.run_check") as mock_run_check:
        mock_run_check.side_effect = lambda *args, **kwargs: print("FACT CHECK PASSED")
        result = _handle_fact_check(
            {"claim": "test claim", "peek": False}, tenant_id="t1"
        )
        assert len(result) == 1
        assert "FACT CHECK PASSED" in result[0].text

@patch("backend.mcp_server.tools.query_graph.get_config")
@patch("backend.mcp_server.tools.query_graph.Neo4jStorageClient")
def test_query_graph_clamps_max_hops_and_orders_by_distance(mock_neo4j_class, mock_get_config):
    mock_instance = mock_neo4j_class.from_config.return_value
    mock_instance.execute_read.return_value = []

    query_graph("Alice", max_hops=10, tenant_id="t1")

    call_args = mock_instance.execute_read.call_args[0]
    query = call_args[0]

    assert "*1..3]" in query
    assert "ORDER BY hop_distance ASC" in query
    assert "ORDER BY min_hops ASC" in query


@patch("backend.mcp_server.tools.query_graph.get_config")
@patch("backend.mcp_server.tools.query_graph.Neo4jStorageClient")
@patch("backend.mcp_server.tools.query_graph.sentry_sdk.capture_exception")
def test_query_graph_hydration_failure_reports_to_sentry(mock_sentry, mock_neo4j_class, mock_get_config):
    mock_neo4j_instance = mock_neo4j_class.from_config.return_value
    mock_neo4j_instance.execute_read.return_value = [
        {
            "id": "node-1",
            "qdrant_point_id": "uuid-1",
            "labels": ["Person"],
            "props": {"name": "Alice"},
        }
    ]

    with patch("backend.storage.qdrant_client.QdrantStorageClient.from_config") as mock_qdrant_from_config:
        mock_qdrant_from_config.side_effect = RuntimeError("Qdrant unreachable")

        hits = query_graph("Alice")

        assert len(hits) == 1
        assert hits[0].id == "uuid-1"
        mock_sentry.assert_called_once()
        assert isinstance(mock_sentry.call_args[0][0], RuntimeError)


def test_handle_merge_rank_seeds_graph_from_query_text_when_payload_lacks_title():
    from backend.mcp_server.handlers.tool_registry import _handle_merge_rank
    from backend.retrieval.merge_rank import VectorHit

    with (
        patch("backend.mcp_server.handlers.tool_registry.search_vectors") as mock_sv,
        patch("backend.mcp_server.handlers.tool_registry.query_graph") as mock_qg,
    ):
        mock_sv.return_value = [
            VectorHit(
                id="c1",
                score=0.9,
                payload={"text": "Standard chunk with no title"},
            )
        ]
        mock_qg.return_value = []

        _handle_merge_rank({"query_text": "Acme Corp debt covenant"}, tenant_id="t1")

        mock_qg.assert_called_once_with(
            entity_name="Acme Corp debt covenant",
            max_hops=2,
            tenant_id="t1",
        )


import asyncio

@patch("backend.retrieval.merge_rank.merge_rank")
def test_execute_tools_internal_passes_query_text_to_merge_rank(mock_merge_rank):
    from backend.mcp_server.tool_dispatch import execute_tools_internal

    with patch("backend.mcp_server.tool_dispatch._execute_single_tool") as mock_exec_single:
        mock_exec_single.return_value = ([], [])
        mock_merge_rank.return_value = []

        tool_calls = [{"name": "search_vectors", "args": {"query_text": "leverage ratio"}}]

        asyncio.run(
            execute_tools_internal(
                tool_calls,
                tenant_id="t1",
                tool_settings={"file_search_enabled": True}
            )
        )

        mock_merge_rank.assert_called_once()
        assert mock_merge_rank.call_args[1].get("query_text") == "leverage ratio"
