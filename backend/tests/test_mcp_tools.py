import asyncio
from unittest.mock import MagicMock, patch

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
@patch("backend.storage.qdrant_client.QdrantStorageClient.from_config")
@patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config")
def test_insert_vectors_success(mock_neo4j_class, mock_qdrant_class, mock_get_config):
    mock_instance = mock_qdrant_class.return_value
    mock_instance.insert_points.return_value = ["uuid-1", "uuid-2"]
    mock_neo4j = mock_neo4j_class.return_value
    mock_neo4j.upsert_entity.return_value = "chunk-node-1"

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
        mock_qg.return_value = [GraphHit(id="chunk-1", payload={"name": "AuthModule"})]

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
def test_query_graph_clamps_max_hops_and_orders_by_distance(
    mock_neo4j_class, mock_get_config
):
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
def test_query_graph_hydration_failure_reports_to_sentry(
    mock_sentry, mock_neo4j_class, mock_get_config
):
    mock_neo4j_instance = mock_neo4j_class.from_config.return_value
    mock_neo4j_instance.execute_read.return_value = [
        {
            "id": "node-1",
            "qdrant_point_id": "uuid-1",
            "labels": ["Person"],
            "props": {"name": "Alice"},
        }
    ]

    with patch(
        "backend.storage.qdrant_client.QdrantStorageClient.from_config"
    ) as mock_qdrant_from_config:
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


@patch("backend.retrieval.merge_rank.merge_rank")
def test_execute_tools_internal_passes_query_text_to_merge_rank(mock_merge_rank):
    from backend.mcp_server.tool_dispatch import execute_tools_internal

    with patch(
        "backend.mcp_server.tool_dispatch._execute_single_tool"
    ) as mock_exec_single:
        mock_exec_single.return_value = ([], [])
        mock_merge_rank.return_value = []

        tool_calls = [
            {"name": "search_vectors", "args": {"query_text": "leverage ratio"}}
        ]

        asyncio.run(
            execute_tools_internal(
                tool_calls, tenant_id="t1", tool_settings={"file_search_enabled": True}
            )
        )

        mock_merge_rank.assert_called_once()
        assert mock_merge_rank.call_args[1].get("query_text") == "leverage ratio"


@patch("backend.retrieval.merge_rank.merge_rank")
def test_execute_tools_internal_auto_seeds_graph_when_vector_hits_present(mock_merge_rank):
    from backend.mcp_server.tool_dispatch import execute_tools_internal
    from backend.retrieval.merge_rank import MergedResult

    v_hit = VectorHit(id="v1", score=0.9, payload={"entity_names": ["Apple"]})
    g_hit = GraphHit(id="v1", payload={"name": "Apple"})
    m_res = MergedResult(id="v1", fused_score=0.9, sources=["vector", "graph"], payload={"entity_names": ["Apple"]})

    with (
        patch("backend.mcp_server.tool_dispatch._execute_single_tool") as mock_exec_single,
        patch("backend.mcp_server.tools.query_graph.seed_graph_hits_from_vectors") as mock_seed,
    ):
        mock_exec_single.return_value = ([v_hit], [])
        mock_seed.return_value = [g_hit]
        mock_merge_rank.return_value = [m_res]

        tool_calls = [
            {"name": "search_vectors", "args": {"query_text": "Apple earnings"}}
        ]

        asyncio.run(
            execute_tools_internal(
                tool_calls, tenant_id="t1", tool_settings={"file_search_enabled": True}
            )
        )

        mock_seed.assert_called_once()
        mock_merge_rank.assert_called_once()
        passed_graph_hits = mock_merge_rank.call_args[0][1]
        assert len(passed_graph_hits) == 1
        assert passed_graph_hits[0].id == "v1"


def test_handle_merge_rank_falls_back_to_query_text_when_payload_title_yields_no_graph_hits():
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
                payload={"title": "Q3 2024 Filing", "text": "Some text"},
            )
        ]
        mock_qg.return_value = []

        _handle_merge_rank({"query_text": "Acme Corp debt covenant"}, tenant_id="t1")

        assert mock_qg.call_count == 2
        mock_qg.assert_any_call(
            entity_name="Q3 2024 Filing",
            max_hops=2,
            tenant_id="t1",
        )
        mock_qg.assert_any_call(
            entity_name="Acme Corp debt covenant",
            max_hops=2,
            tenant_id="t1",
        )


@patch("backend.mcp_server.tools.search_vectors.get_config")
@patch("backend.mcp_server.tools.search_vectors.QdrantStorageClient")
@patch("backend.mcp_server.tools.search_vectors._EMBED_EXECUTOR.submit")
def test_search_vectors_cancels_sparse_future_on_dense_failure(
    mock_submit, mock_qdrant_class, mock_get_config
):
    import pytest
    from backend.mcp_server.tools.search_vectors import search_vectors

    mock_future_dense = MagicMock()
    mock_future_dense.result.side_effect = RuntimeError("Embedding dense failure")
    mock_future_sparse = MagicMock()

    mock_submit.side_effect = [mock_future_dense, mock_future_sparse]

    with pytest.raises(RuntimeError, match="Embedding dense failure"):
        search_vectors("query causing crash")

    mock_future_sparse.cancel.assert_called_once()


def test_handle_merge_rank_seeds_from_entity_names_in_vector_payload():
    from backend.mcp_server.handlers.tool_registry import _handle_merge_rank

    with (
        patch("backend.mcp_server.handlers.tool_registry.search_vectors") as mock_sv,
        patch("backend.mcp_server.handlers.tool_registry.query_graph") as mock_qg,
    ):
        mock_sv.return_value = [
            VectorHit(
                id="c1",
                score=0.9,
                payload={"text": "SVB filed for bankruptcy", "entity_names": ["Silicon Valley Bank"]},
            )
        ]
        mock_qg.return_value = [GraphHit(id="c1", payload={"name": "Silicon Valley Bank"})]

        res = _handle_merge_rank({"query_text": "What caused the collapse?"}, tenant_id="t1")
        assert len(res) == 1
        mock_qg.assert_called_once_with(
            entity_name="Silicon Valley Bank",
            max_hops=2,
            tenant_id="t1",
        )


@patch("backend.mcp_server.tools.query_graph.get_config")
@patch("backend.mcp_server.tools.query_graph.Neo4jStorageClient")
def test_query_graph_supports_pure_graph_nodes_and_source_entity(
    mock_neo4j_class, mock_get_config
):
    mock_neo4j_instance = mock_neo4j_class.from_config.return_value
    mock_neo4j_instance.execute_read.return_value = [
        {
            "id": "node-causal-1",
            "source_entity": "Inflation",
            "qdrant_point_id": "neo4j:node-causal-1",
            "labels": ["Concept"],
            "props": {"name": "Interest Rate"},
            "relation_type": "CAUSES",
            "min_hops": 1,
        }
    ]

    hits = query_graph("Inflation", tenant_id="t1")
    assert len(hits) == 1
    assert hits[0].id == "neo4j:node-causal-1"
    assert hits[0].payload["source_entity"] == "Inflation"
    assert hits[0].payload["relation_type"] == "CAUSES"


@patch("backend.mcp_server.tools.fact_check.search_vectors")
@patch("backend.mcp_server.tools.fact_check.query_graph")
@patch("backend.mcp_server.tools.fact_check.merge_rank")
def test_perform_fact_check_calls_merge_rank_when_graph_hits_present(
    mock_merge_rank, mock_query_graph, mock_search_vectors
):
    from backend.mcp_server.tools.fact_check import perform_fact_check

    v_hit = VectorHit(id="p1", score=0.9, payload={"text": "Inflation rose by 5 percent in 2022."})
    g_hit = GraphHit(id="p1", payload={"name": "Inflation", "source_entity": "Economy"})

    mock_search_vectors.return_value = [v_hit]
    mock_query_graph.return_value = [g_hit]
    mock_merge_rank.return_value = [v_hit]

    res = perform_fact_check(claim="Inflation rose by 5 percent in 2022.", tenant_id="t1")
    assert res["passed"] is True
    mock_query_graph.assert_called_once()
    mock_merge_rank.assert_called_once()


def test_handle_merge_rank_seeds_multiple_entities_across_vector_hits():
    from backend.mcp_server.handlers.tool_registry import _handle_merge_rank

    with (
        patch("backend.mcp_server.handlers.tool_registry.search_vectors") as mock_sv,
        patch("backend.mcp_server.handlers.tool_registry.query_graph") as mock_qg,
    ):
        mock_sv.return_value = [
            VectorHit(
                id="c1",
                score=0.9,
                payload={"text": "SVB collapsed", "entity_names": ["Silicon Valley Bank"]},
            ),
            VectorHit(
                id="c2",
                score=0.85,
                payload={"text": "Federal Reserve increased rates", "entity_names": ["Federal Reserve"]},
            ),
        ]
        mock_qg.side_effect = lambda entity_name, **kwargs: [GraphHit(id=f"g-{entity_name}", payload={"name": entity_name})]

        res = _handle_merge_rank(
            {"query_text": "Did Federal Reserve rates impact Silicon Valley Bank?"},
            tenant_id="t1",
        )
        assert len(res) == 1
        # Confirms both entities were traversed rather than stopping at the first
        called_entities = [call[1]["entity_name"] for call in mock_qg.call_args_list]
        assert "Federal Reserve" in called_entities
        assert "Silicon Valley Bank" in called_entities


@patch("backend.storage.qdrant_client.QdrantStorageClient.from_config")
@patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config")
def test_delete_entity_cleans_qdrant_payloads(mock_neo4j_cls, mock_qdrant_cls):
    from backend.mcp_server.tools.delete_entity import delete_entity

    mock_neo4j = mock_neo4j_cls.return_value
    mock_neo4j.execute_read.return_value = [
        {"id": "node-123", "name": "Acme", "aliases": [], "q_ids": ["point-abc"]}
    ]
    mock_neo4j.execute_write.return_value = [{"deleted_count": 1}]

    mock_qdrant = mock_qdrant_cls.return_value
    mock_qdrant.get_points.return_value = [
        {"id": "point-abc", "payload": {"neo4j_node_ids": ["node-123", "node-456"], "entity_names": ["Acme", "Other"]}}
    ]

    result = delete_entity("Acme", tenant_id="t1")
    assert "Successfully deleted 1 entity(s)" in result
    mock_qdrant.batch_set_payloads.assert_called_once()
    payload_called = mock_qdrant.batch_set_payloads.call_args[1]["payload_by_point_id"]["point-abc"]
    assert "node-123" not in payload_called["neo4j_node_ids"]
    assert "Acme" not in payload_called["entity_names"]
    assert payload_called["entity_names"] == ["Other"]


@patch("backend.storage.qdrant_client.QdrantStorageClient.from_config")
@patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config")
def test_delete_entity_creates_unlinked_chunk_when_last_entity_removed(
    mock_neo4j_cls, mock_qdrant_cls
):
    from backend.mcp_server.tools.delete_entity import delete_entity

    mock_neo4j = mock_neo4j_cls.return_value
    mock_neo4j.execute_read.return_value = [
        {"id": "node-sole", "name": "SoleEntity", "aliases": [], "q_ids": ["point-xyz"]}
    ]
    mock_neo4j.execute_write.return_value = [{"deleted_count": 1}]
    mock_neo4j.upsert_entity.return_value = "chunk-fallback-xyz"

    mock_qdrant = mock_qdrant_cls.return_value
    mock_qdrant.get_points.return_value = [
        {"id": "point-xyz", "payload": {"neo4j_node_ids": ["node-sole"], "entity_names": ["SoleEntity"]}}
    ]

    result = delete_entity("SoleEntity", tenant_id="t1")
    assert "Successfully deleted 1 entity(s)" in result
    mock_neo4j.upsert_entity.assert_called_once()
    call_kwargs = mock_neo4j.upsert_entity.call_args[1]
    assert call_kwargs["label"] == "Chunk"
    assert call_kwargs["qdrant_point_ids"] == ["point-xyz"]

    mock_qdrant.batch_set_payloads.assert_called_once()
    payload_called = mock_qdrant.batch_set_payloads.call_args[1]["payload_by_point_id"]["point-xyz"]
    assert payload_called["neo4j_node_ids"] == ["chunk-fallback-xyz"]
    assert payload_called["entity_names"] == []
    assert payload_called["entity_name"] is None


@patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config")
def test_get_graph_schema_scopes_by_tenant(mock_neo4j_cls):
    from backend.mcp_server.tools.get_schema import get_graph_schema

    mock_neo4j = mock_neo4j_cls.return_value
    mock_neo4j.execute_read.side_effect = [
        [{"label": "TenantA_Entity"}],
        [{"rel_type": "TENANT_A_REL"}],
    ]

    schema = get_graph_schema(tenant_id="tenant_a")
    assert schema["node_labels"] == ["TenantA_Entity"]
    assert schema["relationship_types"] == ["TENANT_A_REL"]
    assert mock_neo4j.execute_read.call_args_list[0][0][1]["tenant_id"] == "tenant_a"


@patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config")
def test_get_graph_schema_empty_tenant_no_leakage(mock_neo4j_cls):
    from backend.mcp_server.tools.get_schema import get_graph_schema

    mock_neo4j = mock_neo4j_cls.return_value
    mock_neo4j.execute_read.side_effect = [[], []]

    schema = get_graph_schema(tenant_id="empty_tenant")
    assert schema["node_labels"] == []
    assert schema["relationship_types"] == []
    # Assert only 2 queries executed (labels and rels for tenant) and no db.labels() fallback
    assert mock_neo4j.execute_read.call_count == 2
    for call in mock_neo4j.execute_read.call_args_list:
        assert "CALL db." not in call[0][0]
        assert call[0][1].get("tenant_id") == "empty_tenant"


@patch("backend.mcp_server.tools.insert_vector.get_config")
@patch("backend.storage.qdrant_client.QdrantStorageClient.from_config")
@patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config")
def test_insert_vectors_rolls_back_qdrant_points_on_neo4j_sync_failure(
    mock_neo4j_cls, mock_qdrant_cls, mock_get_config
):
    import pytest
    from backend.mcp_server.tools.insert_vector import insert_vectors

    mock_qdrant = mock_qdrant_cls.return_value
    mock_qdrant.insert_points.return_value = ["pt-1", "pt-2"]

    mock_neo4j = mock_neo4j_cls.return_value
    mock_neo4j.upsert_entity.side_effect = RuntimeError("Neo4j database write failure")

    with pytest.raises(RuntimeError, match="Neo4j database write failure"):
        insert_vectors(["hello world", "test chunk"], tenant_id="t1")

    # Verify compensating rollback deleted the orphaned points from Qdrant
    mock_qdrant.delete_points.assert_called_once()
    deleted_pids = mock_qdrant.delete_points.call_args[1]["point_ids"]
    assert deleted_pids == ["pt-1", "pt-2"]


def test_write_to_graph_preserves_source_point_ids_provenance():
    from backend.ingestion.graph_write import IngestionPayload, write_to_graph

    mock_neo4j = MagicMock()
    mock_neo4j.upsert_entity.return_value = "node-provenance-1"

    payload = IngestionPayload(
        entities=[
            {
                "name": "General Electric",
                "type": "Company",
                "aliases": [],
                "source_point_ids": ["pt-page-42"],
            }
        ],
        relations=[],
        qdrant_point_ids={
            "Title page chunk 1": "pt-page-1",
            "Page 42 content about financial results": "pt-page-42",
        },
    )

    _, q2n, _ = write_to_graph(mock_neo4j, payload, tenant_id="t1")
    assert "pt-page-42" in q2n
    call_kwargs = mock_neo4j.upsert_entity.call_args_list[0][1]
    assert call_kwargs["name"] == "General Electric"
    assert call_kwargs["qdrant_point_ids"] == ["pt-page-42"]
    assert "pt-page-1" not in call_kwargs["qdrant_point_ids"]


def test_qdrant_batch_set_payloads_groups_identical_payloads():
    from backend.storage.qdrant_client import QdrantStorageClient

    client = QdrantStorageClient(url=":memory:")
    mock_inner_client = MagicMock()
    client.client = mock_inner_client

    payload_by_id = {
        "p1": {"neo4j_node_ids": ["n1"], "entity_name": "Acme"},
        "p2": {"neo4j_node_ids": ["n1"], "entity_name": "Acme"},
        "p3": {"neo4j_node_ids": ["n2"], "entity_name": "Beta"},
    }

    client.batch_set_payloads("test_coll", payload_by_id)

    # Should group p1 and p2 into 1 call, and p3 into another (2 calls total instead of 3)
    assert mock_inner_client.set_payload.call_count == 2
    called_point_groups = [
        call[1]["points"] for call in mock_inner_client.set_payload.call_args_list
    ]
    assert ["p1", "p2"] in called_point_groups or ["p2", "p1"] in called_point_groups
    assert ["p3"] in called_point_groups


@patch("backend.ingestion.__main__.get_config")
@patch("backend.ingestion.__main__.QdrantStorageClient.from_config")
@patch("backend.ingestion.__main__.Neo4jStorageClient.from_config")
@patch("backend.ingestion.__main__.chunk_and_embed")
@patch("backend.ingestion.__main__.extract_entities_and_relations")
def test_run_ingestion_rolls_back_qdrant_points_on_neo4j_failure(
    mock_extract, mock_chunk_embed, mock_neo4j_cls, mock_qdrant_cls, mock_get_cfg
):
    import pytest
    from backend.ingestion.__main__ import run_ingestion

    mock_cfg = mock_get_cfg.return_value
    mock_cfg.qdrant_collection_name = "test_collection"

    mock_qdrant = mock_qdrant_cls.return_value
    mock_qdrant.has_file_hash.return_value = False
    mock_qdrant.insert_points.return_value = ["point-1", "point-2"]

    mock_chunk_embed.return_value = [
        ("Chunk 1 text", [0.1] * 384, {"indices": [], "values": []}),
        ("Chunk 2 text", [0.2] * 384, {"indices": [], "values": []}),
    ]
    mock_extract.return_value = ([{"name": "Apple", "type": "Company"}], [])

    mock_neo4j = mock_neo4j_cls.return_value
    mock_neo4j.upsert_entity.side_effect = RuntimeError("Neo4j disk failure during graph write")

    schema = {"entities": ["Company"], "relations": {}}
    with pytest.raises(RuntimeError, match="Neo4j disk failure"):
        run_ingestion(mock_cfg, "Some document text", schema, tenant_id="tenant-123")

    # Verify rollback was called to prevent file_hash poisoning
    mock_qdrant.delete_points.assert_called_once_with("test_collection", ["point-1", "point-2"])


def test_write_to_graph_collision_safe_chunk_pairs():
    from backend.ingestion.graph_write import IngestionPayload, write_to_graph

    mock_neo4j = MagicMock()
    mock_neo4j.upsert_entity.return_value = "node-chunk-safe"

    # Two identical chunk texts on different pages with different point IDs
    chunk_pairs = [
        ("Chapter Title", "pid-page-1"),
        ("Chapter Title", "pid-page-2"),
    ]
    payload = IngestionPayload(
        entities=[{"name": "Chapter Title", "type": "Concept", "aliases": []}],
        relations=[],
        qdrant_point_ids=chunk_pairs,
    )

    _, q2n, _ = write_to_graph(mock_neo4j, payload, tenant_id="tenant-123")
    assert "pid-page-1" in q2n
    assert "pid-page-2" in q2n


def test_write_to_graph_multi_chunk_unmatched_entity_not_attributed_to_chunk_0():
    from backend.ingestion.graph_write import IngestionPayload, write_to_graph

    mock_neo4j = MagicMock()
    mock_neo4j.upsert_entity.return_value = "node-unmatched"

    chunk_pairs = [
        ("Introduction to organic chemistry on page 1", "pid-intro-1"),
        ("Advanced biochemistry synthesis on page 50", "pid-bio-50"),
    ]
    # Entity has no match in either chunk text
    payload = IngestionPayload(
        entities=[{"name": "Quantum Electrodynamics", "type": "Concept", "aliases": []}],
        relations=[],
        qdrant_point_ids=chunk_pairs,
    )

    _, _q2n, _ = write_to_graph(mock_neo4j, payload, tenant_id="tenant-123")
    call_kwargs = mock_neo4j.upsert_entity.call_args_list[0][1]
    assert call_kwargs["name"] == "Quantum Electrodynamics"
    # Should NOT default to pid-intro-1
    assert "pid-intro-1" not in call_kwargs["qdrant_point_ids"]
    assert call_kwargs["qdrant_point_ids"] == []


@patch("backend.storage.qdrant_client.QdrantStorageClient.from_config")
def test_update_document_metadata_tenant_validation_and_stripping(mock_qdrant_cls):
    from backend.mcp_server.tools.update_document import update_document_metadata

    mock_qdrant = mock_qdrant_cls.return_value
    # 1. Point not found
    mock_qdrant.get_points.return_value = []
    res = update_document_metadata("doc-missing", {"key": "val"}, tenant_id="t1")
    assert "not found" in res

    # 2. Unauthorized cross-tenant attempt
    mock_qdrant.get_points.return_value = [{"id": "doc-1", "payload": {"tenant_id": "tenant-other"}}]
    res = update_document_metadata("doc-1", {"key": "val"}, tenant_id="t1")
    assert "Unauthorized" in res

    # 3. Successful update stripping reserved link keys
    mock_qdrant.get_points.return_value = [{"id": "doc-1", "payload": {"tenant_id": "t1"}}]
    res = update_document_metadata(
        "doc-1",
        {"key": "val", "neo4j_node_ids": ["rogue-node"], "file_hash": "bad-hash", "tenant_id": "other"},
        tenant_id="t1",
    )
    assert "Successfully updated" in res
    mock_qdrant.client.set_payload.assert_called_once()
    saved_payload = mock_qdrant.client.set_payload.call_args[1]["payload"]
    assert saved_payload["tenant_id"] == "t1"
    assert "neo4j_node_ids" not in saved_payload
    assert "file_hash" not in saved_payload
    assert saved_payload["key"] == "val"


@patch("backend.storage.neo4j_client.Neo4jStorageClient.from_config")
def test_update_entity_strips_reserved_properties(mock_neo4j_cls):
    from backend.mcp_server.tools.update_entity import update_entity

    mock_neo4j = mock_neo4j_cls.return_value
    mock_neo4j.execute_write.return_value = [{"updated_count": 1}]

    res = update_entity(
        "Acme Corp",
        {"rating": "AAA", "tenant_id": "rogue", "entity_key": "bad_key", "qdrant_point_ids": ["p1"]},
        tenant_id="t1",
    )
    assert "Successfully updated" in res
    written_props = mock_neo4j.execute_write.call_args[0][1]["properties"]
    assert written_props == {"rating": "AAA"}


@patch("backend.mcp_server.handlers.tool_registry.run_community_detection")
def test_handle_run_community_detection_passes_tenant_id(mock_rcd):
    from backend.mcp_server.handlers.tool_registry import _handle_run_community_detection

    mock_rcd.return_value = [{"community": "1", "size": 3}]
    res = _handle_run_community_detection({"min_size": 3}, tenant_id="my-tenant")
    assert len(res) == 1
    mock_rcd.assert_called_once_with(3, tenant_id="my-tenant")
