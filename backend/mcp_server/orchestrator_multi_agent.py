import logging
from typing import TypedDict

from langgraph.graph import END, START, StateGraph
from pydantic import BaseModel, Field

from backend.config import get_config
from backend.mcp_server.orchestrator import _create_chat_llm
from backend.mcp_server.tools.web_search import mcp_web_search

logger = logging.getLogger(__name__)


class DebateState(TypedDict, total=False):
    query: str
    tenant_id: str
    vector_data: str
    graph_data: str
    web_data: str
    research_data: str
    draft: str
    critique: str
    grounding_score: float
    is_approved: bool
    iterations: int
    tool_settings: dict
    vector_hits: list
    graph_hits: list


async def vector_specialist_node(state: DebateState):
    """Vector Specialist Subagent: Retrieves top-k dense and sparse vector chunks from Qdrant."""
    query = state["query"]
    tenant_id = state.get("tenant_id", "default")
    logger.info(f"Multi-Agent: Vector Specialist searching for '{query}'...")

    try:
        from backend.mcp_server.tools.search_vectors import search_vectors

        hits = search_vectors(query, limit=5, tenant_id=tenant_id)
        snippets = []
        for i, hit in enumerate(hits, 1):
            text = (
                hit.payload.get("text")
                or hit.payload.get("content")
                or str(hit.payload)
            )
            source = (
                hit.payload.get("source")
                or hit.payload.get("document_id")
                or "Unknown Document"
            )
            page = hit.payload.get("page_number")
            loc = f" | Page {page}" if page is not None else ""
            snippets.append(
                f"[Vector Source {i}: {source}{loc}] (chunk {hit.id}): {text}"
            )
        vector_data = "\n\n".join(snippets) if snippets else ""
    except Exception as e:
        logger.warning(f"Vector specialist search failed: {e}")
        hits = []
        vector_data = ""

    return {"vector_data": vector_data, "vector_hits": hits}


async def graph_specialist_node(state: DebateState):
    """Graph Specialist Subagent: Traverses Neo4j for causal chains, entities, and relationship paths."""
    query = state["query"]
    tenant_id = state.get("tenant_id", "default")
    logger.info(f"Multi-Agent: Graph Specialist querying paths for '{query}'...")

    try:
        from backend.mcp_server.tools.query_graph import (
            query_graph,
            seed_graph_hits_from_vectors,
        )
        from backend.mcp_server.tools.search_vectors import search_vectors

        graph_hits = query_graph(entity_name=query, max_hops=2, tenant_id=tenant_id)
        if not graph_hits:
            v_hits = search_vectors(query, limit=3, tenant_id=tenant_id)
            graph_hits = seed_graph_hits_from_vectors(
                v_hits=v_hits,
                query_text=query,
                max_hops=2,
                tenant_id=tenant_id,
                max_seeds=3,
                query_graph_fn=query_graph,
            )

        graph_snippets = []
        for i, hit in enumerate(graph_hits[:10], 1):
            payload = hit.payload or {}
            src = payload.get("source_entity")
            name = payload.get("name") or payload.get("title") or hit.id
            rel = payload.get("relation_type") or "CONNECTED_TO"
            labels = payload.get("labels", [])
            lbl_str = f" ({', '.join(labels)})" if labels else ""
            txt = payload.get("text")
            txt_str = f' - "{txt[:120]}..."' if txt else ""
            if src:
                graph_snippets.append(
                    f"[Graph Relation {i}]: ({src}) ──[{rel}]──▶ ({name}{lbl_str}){txt_str}"
                )
            else:
                graph_snippets.append(
                    f"[Graph Relation {i}]: ({name}{lbl_str}) [rel: {rel}]{txt_str}"
                )

        graph_data = "\n".join(graph_snippets) if graph_snippets else ""
    except Exception as e:
        logger.warning(f"Graph specialist query failed: {e}")
        graph_hits = []
        graph_data = ""

    return {"graph_data": graph_data, "graph_hits": graph_hits}


async def web_specialist_node(state: DebateState):
    """Web Specialist Subagent: Fetches live external web information as fallback or enrichment."""
    query = state["query"]
    tool_settings = state.get("tool_settings") or {}
    logger.info(f"Multi-Agent: Web Specialist searching for '{query}'...")

    try:
        results = mcp_web_search(query, tool_settings=tool_settings)
        context = []
        for i, res in enumerate(results[:5], 1):
            context.append(f"[Web Source {i}] ({res.get('url')}): {res.get('content')}")
        web_data = "\n\n".join(context) if context else ""
    except Exception as e:
        logger.warning(f"Web specialist search failed: {e}")
        web_data = ""

    return {"web_data": web_data}


async def synthesizer_node(state: DebateState):
    """Evidence Synthesizer: Fuses findings from Vector, Graph, and Web specialists into unified evidence."""
    sections = []
    vector_hits = state.get("vector_hits") or []
    graph_hits = state.get("graph_hits") or []
    query = state.get("query", "")

    if vector_hits or graph_hits:
        try:
            from backend.retrieval.merge_rank import merge_rank

            fused_results = merge_rank(
                vector_hits=vector_hits,
                graph_hits=graph_hits,
                query_text=query,
            )
            fused_snippets = []
            for i, res in enumerate(fused_results[:6], 1):
                text = (
                    res.payload.get("text")
                    or res.payload.get("content")
                    or str(res.payload)
                )
                src = (
                    res.payload.get("source")
                    or res.payload.get("document_id")
                    or "Knowledge Store"
                )
                fused_snippets.append(
                    f"[Fused Evidence {i}: {src}] (Score: {res.fused_score:.3f}): {text}"
                )
            if fused_snippets:
                sections.append(
                    "### Fused Hybrid Evidence (RRF Ranked):\n"
                    + "\n\n".join(fused_snippets)
                )
        except Exception as e:
            logger.warning(f"Failed running merge_rank in synthesizer_node: {e}")

    if state.get("vector_data"):
        sections.append("### Vector Evidence (Qdrant):\n" + state["vector_data"])
    if state.get("graph_data"):
        sections.append("### Graph Relations (Neo4j):\n" + state["graph_data"])
    if state.get("web_data"):
        sections.append("### Live Web Findings:\n" + state["web_data"])

    research_data = "\n\n".join(sections) if sections else "No research evidence found."
    return {"research_data": research_data}


async def writer_node(state: DebateState):
    """Writer Subagent: Synthesizes a factual, analytical answer grounded strictly in multi-specialist data."""
    config = get_config()
    llm = _create_chat_llm(config.llm_model_name, config.llm_api_key)

    query = state["query"]
    research_data = state.get("research_data", "")
    critique = state.get("critique", "")

    logger.info("Multi-Agent: Writer synthesizing response...")

    prompt = f"""You are the Writer agent in a multi-agent GraphRAG research team.
Your job is to answer the user's query based ONLY on the provided Research Data.
You must cite your sources inline using brackets like [Fused Evidence X], [Vector Source X], [Graph Relation X], or [Web Source X].

User Query: {query}

Research Data:
{research_data}
"""
    if critique:
        prompt += f"\n\nPrevious Critique from the Skeptic Verifier:\n{critique}\nPlease correct the draft to address all cited issues."

    response = await llm.ainvoke(prompt)

    return {
        "draft": str(response.content),
        "iterations": state.get("iterations", 0) + 1,
    }


class SkepticEvaluation(BaseModel):
    critique: str = Field(
        description="Detailed explanation of any factual errors, missing citations, or unsupported claims. Leave empty if well grounded."
    )
    is_approved: bool = Field(
        description="True if the draft is accurately supported by the research data, False otherwise."
    )


async def skeptic_node(state: DebateState):
    """Skeptic / Grounding Verifier Subagent: Critiques the draft against the evidence data."""
    config = get_config()
    llm = _create_chat_llm(config.llm_model_name, config.llm_api_key)
    structured_llm = llm.with_structured_output(
        SkepticEvaluation, method="function_calling"
    )

    draft = state.get("draft", "")
    research_data = state.get("research_data", "")

    logger.info("Multi-Agent: Skeptic evaluating draft grounding...")

    # 1. Quantitative grounding score
    grounding_score = 1.0
    try:
        from backend.mcp_server.tools.evaluate_grounding import mcp_evaluate_grounding

        grounding_score = float(mcp_evaluate_grounding(draft, research_data))
    except Exception as e:
        logger.warning(f"Grounding score evaluation failed: {e}")

    # 2. Qualitative critique
    prompt = f"""You are the Skeptic / Verifier agent. Your job is to aggressively fact-check the Writer's draft against the Research Data.
If the Writer makes ANY claim that is not explicitly supported by the Research Data, or fails to cite it, you must reject it (is_approved=False) and provide a constructive critique.

Research Data:
{research_data}

Writer's Draft:
{draft}
"""

    try:
        eval_result = await structured_llm.ainvoke(prompt)
        is_approved = eval_result.is_approved and (grounding_score >= 0.70)
        critique = eval_result.critique
    except Exception as e:
        import sentry_sdk

        sentry_sdk.capture_exception(e)
        logger.error(f"Skeptic node evaluation failed: {e}")
        # Fail closed on evaluation failure: require high deterministic score to approve
        is_approved = grounding_score >= 0.85
        critique = (
            f"Automated skeptic LLM evaluation encountered an error ({e}). "
            f"Verification required deterministic grounding >= 0.85 (got {grounding_score:.2f})."
        )

    logger.info(
        f"Multi-Agent: Skeptic approval: {is_approved} (Grounding Score: {grounding_score:.2f})"
    )
    return {
        "is_approved": is_approved,
        "critique": critique,
        "grounding_score": grounding_score,
    }


def debate_router(state: DebateState) -> str:
    """Routes based on Skeptic approval or iteration limit."""
    if state.get("is_approved", False) or state.get("iterations", 0) >= 3:
        return END
    return "writer"


def get_debate_workflow():
    workflow = StateGraph(DebateState)
    workflow.add_node("vector_specialist", vector_specialist_node)
    workflow.add_node("graph_specialist", graph_specialist_node)
    workflow.add_node("web_specialist", web_specialist_node)
    workflow.add_node("synthesizer", synthesizer_node)
    workflow.add_node("writer", writer_node)
    workflow.add_node("skeptic", skeptic_node)

    # Parallel retrieval across specialists
    workflow.add_edge(START, "vector_specialist")
    workflow.add_edge(START, "graph_specialist")
    workflow.add_edge(START, "web_specialist")

    workflow.add_edge("vector_specialist", "synthesizer")
    workflow.add_edge("graph_specialist", "synthesizer")
    workflow.add_edge("web_specialist", "synthesizer")

    workflow.add_edge("synthesizer", "writer")
    workflow.add_edge("writer", "skeptic")
    workflow.add_conditional_edges(
        "skeptic", debate_router, {"writer": "writer", END: END}
    )

    return workflow


async def mcp_agentic_debate(
    query: str, tenant_id: str = "default", tool_settings: dict | None = None
) -> dict:
    """Entrypoint function to run the specialized multi-agent GraphRAG workflow."""
    logger.info(f"Starting Multi-Agent GraphRAG Workflow for query: {query}")

    workflow = get_debate_workflow()
    app = workflow.compile()

    initial_state = {
        "query": query,
        "tenant_id": tenant_id,
        "tool_settings": tool_settings or {},
        "iterations": 0,
        "vector_data": "",
        "graph_data": "",
        "web_data": "",
        "research_data": "",
        "draft": "",
        "critique": "",
        "grounding_score": 1.0,
        "is_approved": False,
    }

    # Run the graph asynchronously
    final_state = await app.ainvoke(initial_state)

    return {
        "results": [
            {
                "id": "multi_agent_result",
                "text": final_state.get("draft", "No draft produced."),
                "sources": ["Multi-Agent Verified GraphRAG"],
                "grounding_score": final_state.get("grounding_score", 1.0),
                "iterations": final_state.get("iterations", 1),
            }
        ]
    }
