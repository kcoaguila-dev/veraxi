from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from langchain_core.messages import AIMessage

from backend.mcp_server.orchestrator_multi_agent import (
    SkepticEvaluation,
    debate_router,
    graph_specialist_node,
    mcp_agentic_debate,
    skeptic_node,
    synthesizer_node,
    vector_specialist_node,
    web_specialist_node,
    writer_node,
)
from backend.retrieval.merge_rank import VectorHit


@pytest.mark.asyncio
async def test_vector_specialist_node():
    mock_hits = [
        VectorHit(
            id="vec1",
            score=0.95,
            payload={
                "text": "Black-Scholes-Merton model calculates European option pricing."
            },
        )
    ]
    with patch(
        "backend.mcp_server.tools.search_vectors.search_vectors",
        return_value=mock_hits,
    ):
        state = {
            "query": "Explain BSM",
            "tenant_id": "test_tenant",
        }
        res = await vector_specialist_node(state)  # type: ignore
        assert "Vector Source 1" in res["vector_data"]
        assert "Black-Scholes-Merton" in res["vector_data"]


@pytest.mark.asyncio
async def test_graph_specialist_node():
    mock_records = [
        {
            "from_ent": "Black-Scholes-Merton",
            "rel": "APPLIED_TO",
            "to_ent": "Options Pricing",
            "props": {"year": 1973},
        }
    ]
    with patch(
        "backend.storage.neo4j_client.Neo4jStorageClient.from_config"
    ) as mock_neo4j:
        mock_instance = mock_neo4j.return_value
        mock_instance.execute_read.return_value = mock_records

        state = {
            "query": "Black-Scholes-Merton options",
            "tenant_id": "test_tenant",
        }
        res = await graph_specialist_node(state)  # type: ignore
        assert "Graph Relation 1" in res["graph_data"]
        assert "APPLIED_TO" in res["graph_data"]


@pytest.mark.asyncio
async def test_web_specialist_node():
    mock_web_results = [
        {"url": "https://example.com/bsm", "content": "BSM formula breakdown."}
    ]
    with patch(
        "backend.mcp_server.orchestrator_multi_agent.mcp_web_search",
        return_value=mock_web_results,
    ):
        state = {
            "query": "BSM formula",
            "tool_settings": {},
        }
        res = await web_specialist_node(state)  # type: ignore
        assert "Web Source 1" in res["web_data"]
        assert "https://example.com/bsm" in res["web_data"]


@pytest.mark.asyncio
async def test_synthesizer_node():
    state = {
        "vector_data": "[Vector Source 1]: Chunk text",
        "graph_data": "[Graph Relation 1]: (A)->(B)",
        "web_data": "[Web Source 1]: Web snippet",
    }
    res = await synthesizer_node(state)  # type: ignore
    assert "Vector Evidence" in res["research_data"]
    assert "Graph Relations" in res["research_data"]
    assert "Live Web Findings" in res["research_data"]


@pytest.mark.asyncio
async def test_writer_node():
    mock_llm = AsyncMock()
    mock_llm.ainvoke.return_value = AIMessage(
        content="The BSM formula [Vector Source 1] is widely used in finance."
    )

    with patch(
        "backend.mcp_server.orchestrator_multi_agent._create_chat_llm",
        return_value=mock_llm,
    ):
        state = {
            "query": "What is BSM?",
            "research_data": "[Vector Source 1]: BSM formula overview",
            "critique": "",
            "iterations": 0,
        }
        res = await writer_node(state)  # type: ignore
        assert "BSM formula" in res["draft"]
        assert res["iterations"] == 1


@pytest.mark.asyncio
async def test_skeptic_node_approved():
    mock_llm = MagicMock()
    mock_structured = AsyncMock()
    mock_structured.ainvoke.return_value = SkepticEvaluation(
        is_approved=True, critique=""
    )
    mock_llm.with_structured_output.return_value = mock_structured

    with (
        patch(
            "backend.mcp_server.orchestrator_multi_agent._create_chat_llm",
            return_value=mock_llm,
        ),
        patch(
            "backend.mcp_server.tools.evaluate_grounding.mcp_evaluate_grounding",
            return_value="0.95",
        ),
    ):
        state = {
            "draft": "Well grounded claim [Vector Source 1].",
            "research_data": "Evidence text",
        }
        res = await skeptic_node(state)  # type: ignore
        assert res["is_approved"] is True
        assert res["grounding_score"] == 0.95
        assert res["critique"] == ""


def test_debate_router():
    assert debate_router({"is_approved": True, "iterations": 1}) == "__end__"
    assert debate_router({"is_approved": False, "iterations": 3}) == "__end__"
    assert debate_router({"is_approved": False, "iterations": 1}) == "writer"


@pytest.mark.asyncio
async def test_full_mcp_agentic_debate_workflow():
    mock_llm = MagicMock()
    mock_llm.ainvoke = AsyncMock(
        return_value=AIMessage(content="Final synthesized verified answer.")
    )

    mock_structured = AsyncMock()
    mock_structured.ainvoke.return_value = SkepticEvaluation(
        is_approved=True, critique=""
    )
    mock_llm.with_structured_output.return_value = mock_structured

    with (
        patch(
            "backend.mcp_server.orchestrator_multi_agent._create_chat_llm",
            return_value=mock_llm,
        ),
        patch(
            "backend.mcp_server.tools.search_vectors.search_vectors",
            return_value=[],
        ),
        patch(
            "backend.storage.neo4j_client.Neo4jStorageClient.from_config"
        ) as mock_neo4j,
        patch(
            "backend.mcp_server.orchestrator_multi_agent.mcp_web_search",
            return_value=[],
        ),
        patch(
            "backend.mcp_server.tools.evaluate_grounding.mcp_evaluate_grounding",
            return_value="0.90",
        ),
    ):
        mock_instance = mock_neo4j.return_value
        mock_instance.execute_read.return_value = []

        result = await mcp_agentic_debate(query="Test query", tenant_id="test_tenant")
        assert "results" in result
        assert result["results"][0]["text"] == "Final synthesized verified answer."
        assert result["results"][0]["grounding_score"] == 0.90
