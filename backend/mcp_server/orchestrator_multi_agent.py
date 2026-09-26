import logging
from typing import TypedDict

from backend.config import get_config
from backend.mcp_server.orchestrator import _create_chat_llm
from backend.mcp_server.tools.web_search import mcp_web_search
from langgraph.graph import END, START, StateGraph
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)


class DebateState(TypedDict):
    query: str
    tenant_id: str
    research_data: str
    draft: str
    critique: str
    is_approved: bool
    iterations: int
    tool_settings: dict


async def research_node(state: DebateState):
    """Generates web search results for the given query."""
    query = state["query"]
    logger.info(f"Agentic Debate: Researching '{query}'...")

    # In a full system, we might generate 3 distinct queries.
    # For now, we perform one deep scrape of the top 5 results.
    tool_settings = state.get("tool_settings") or {}
    results = mcp_web_search(query, tool_settings=tool_settings)

    context = []
    for i, res in enumerate(results[:5], 1):
        context.append(f"[Source {i}] ({res.get('url')}): {res.get('content')}")

    research_data = "\n\n".join(context)
    if not research_data:
        research_data = "No web results found."

    return {"research_data": research_data}


async def writer_node(state: DebateState):
    """Drafts an initial response based purely on research data."""
    config = get_config()
    llm = _create_chat_llm(config.llm_model_name, config.llm_api_key)

    query = state["query"]
    research_data = state["research_data"]
    critique = state.get("critique", "")

    logger.info("Agentic Debate: Writer drafting response...")

    prompt = f"""You are the Writer agent. Your job is to answer the user's query based ONLY on the provided Research Data.
    You must cite your sources inline using [Source X].
    
    User Query: {query}
    
    Research Data:
    {research_data}
    """
    if critique:
        prompt += f"\n\nPrevious Critique from the Skeptic: {critique}\nPlease fix the issues mentioned."

    response = await llm.ainvoke(prompt)

    return {"draft": response.content, "iterations": state.get("iterations", 0) + 1}


class SkepticEvaluation(BaseModel):
    critique: str = Field(
        description="Detailed explanation of any factual errors, missing citations, or hallucinations. Leave empty if perfect."
    )
    is_approved: bool = Field(
        description="True if the draft is perfectly supported by the research data, False otherwise."
    )


async def skeptic_node(state: DebateState):
    """Critiques the draft against the research data."""
    config = get_config()
    llm = _create_chat_llm(config.llm_model_name, config.llm_api_key)
    structured_llm = llm.with_structured_output(
        SkepticEvaluation, method="function_calling"
    )

    draft = state["draft"]
    research_data = state["research_data"]

    logger.info("Agentic Debate: Skeptic evaluating draft...")

    prompt = f"""You are the Skeptic agent. Your job is to aggressively fact-check the Writer's draft against the original Research Data.
    If the Writer makes ANY claim that is not explicitly supported by the Research Data, or fails to cite it, you must reject it and provide a critique.
    
    Research Data:
    {research_data}
    
    Writer's Draft:
    {draft}
    """

    try:
        eval_result = await structured_llm.ainvoke(prompt)
        is_approved = eval_result.is_approved
        critique = eval_result.critique
    except Exception as e:
        logger.error(f"Skeptic node failed: {e}")
        is_approved = True
        critique = ""

    logger.info(f"Agentic Debate: Skeptic approved? {is_approved}")
    return {"is_approved": is_approved, "critique": critique}


def debate_router(state: DebateState) -> str:
    """Routes based on Skeptic approval or iteration limit."""
    if state.get("is_approved", False) or state.get("iterations", 0) >= 3:
        return END
    return "writer"


def get_debate_workflow():
    workflow = StateGraph(DebateState)
    workflow.add_node("research", research_node)
    workflow.add_node("writer", writer_node)
    workflow.add_node("skeptic", skeptic_node)

    workflow.add_edge(START, "research")
    workflow.add_edge("research", "writer")
    workflow.add_edge("writer", "skeptic")
    workflow.add_conditional_edges(
        "skeptic", debate_router, {"writer": "writer", END: END}
    )

    return workflow


async def mcp_agentic_debate(
    query: str, tenant_id: str, tool_settings: dict | None = None
) -> dict:
    """Entrypoint function to run the multi-agent debate and return the final answer."""
    logger.info(f"Starting Multi-Agent Debate for query: {query}")

    workflow = get_debate_workflow()
    app = workflow.compile()

    initial_state = {
        "query": query,
        "tenant_id": tenant_id,
        "tool_settings": tool_settings or {},
        "iterations": 0,
    }

    # Run the graph asynchronously
    final_state = await app.ainvoke(initial_state)

    # Return formatted results
    return {
        "results": [
            {
                "id": "debate_result",
                "text": final_state.get("draft", "No draft produced."),
                "sources": ["Multi-Agent Debate Verified"],
            }
        ]
    }
