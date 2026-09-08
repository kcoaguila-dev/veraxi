import asyncio
import json
import logging
import os
import time
import urllib.parse
import urllib.request
from collections.abc import Sequence
from typing import Annotated, Any, TypedDict

import sentry_sdk
from backend.config import get_config
from backend.mcp_server.formatter import (
    _finalize_metrics,
    _prepend_system_messages,
)
from backend.mcp_server.tool_dispatch import get_tools
from langchain_core.messages import (
    AIMessage,
    BaseMessage,
    HumanMessage,
    SystemMessage,
    ToolMessage,
)
from langchain_openai import ChatOpenAI
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

from contextvars import ContextVar

_request_model: ContextVar[str | None] = ContextVar("_request_model", default=None)
_request_api_key: ContextVar[str | None] = ContextVar("_request_api_key", default=None)
_request_base_url: ContextVar[str | None] = ContextVar("_request_base_url", default=None)

def _create_chat_llm(model_name: str, api_key: str | None, base_url: str | None = None):
    """Build the configured chat LLM client for the active provider."""
    config = get_config()

    if config.is_enterprise:
        api_key = None
        base_url = None

    llm_args = config.get_llm_client_args(model_name=model_name)
    if api_key:
        llm_args["api_key"] = api_key
    if base_url:
        llm_args["base_url"] = base_url

    base_url = llm_args.get("base_url", "")
    if "api.groq.com" in base_url:
        from langchain_groq import ChatGroq

        groq_api_key = llm_args.pop("api_key", None)
        llm_args.pop("base_url", None)
        return ChatGroq(
            model=model_name,
            temperature=0,
            api_key=groq_api_key,
            **llm_args,
        )

    return ChatOpenAI(
        model=model_name,
        temperature=0,
        **llm_args,
    )


class AgentState(TypedDict):
    messages: Annotated[Sequence[BaseMessage], add_messages]
    tenant_id: str
    context_relevance: str
    retrieved_context: str
    query_embedding: list[float] | None
    calculate_grounding: bool
    tool_settings: dict | None


def _get_workflow():
    workflow = StateGraph(AgentState)
    workflow.add_node("agent", call_model)
    workflow.add_node("tools", execute_tools)
    workflow.add_node("evaluate", evaluate_context)
    workflow.add_node("web_search", web_search_fallback)

    workflow.add_edge(START, "agent")
    workflow.add_conditional_edges("agent", should_continue, ["tools", END])
    workflow.add_edge("tools", "evaluate")
    workflow.add_conditional_edges(
        "evaluate", route_evaluation, ["agent", "web_search"]
    )
    workflow.add_edge("web_search", "agent")

    return workflow


async def call_model(state: AgentState):
    """The AI Agent node that decides what to do."""
    messages = state["messages"]
    started_at = time.perf_counter()

    config = get_config()

    effective_model = _request_model.get() or config.llm_model_name

    # Inherit base args (including the gemini url injection if applicable)
    config.get_llm_client_args(model_name=effective_model)

    # Prefer a per-request key (set by the caller via _request_api_key contextvar)
    # over the server-wide LLM_API_KEY so users can supply their own key via the UI.
    effective_api_key = _request_api_key.get() or config.llm_api_key
    effective_base_url = _request_base_url.get() or None
    llm = _create_chat_llm(effective_model, effective_api_key, effective_base_url)

    # Check if artifacts are enabled to inject system prompt
    tool_settings = state.get("tool_settings") or {}
    artifacts_enabled = tool_settings.get("artifacts_enabled", False)

    extra_system_messages: list[SystemMessage] = []
    if artifacts_enabled:
        extra_system_messages.append(
            SystemMessage(
                content=(
                    "Artifacts are enabled. You can generate UI components, code snippets, or diagrams for the user to view. "
                    "To generate an artifact, output a markdown block with the language set to the artifact type, e.g. "
                    "```html\n<h1>Hello</h1>\n``` or ```mermaid\ngraph TD; A-->B;\n```. "
                    "Make sure your artifacts are entirely self-contained."
                )
            )
        )

    modified_messages = _prepend_system_messages(messages, extra_system_messages)

    # Determine if we should bind tools. We do not bind tools if we are executing a fallback,
    # OR if we just received a ToolMessage (to prevent the LLM from hallucinating more tool calls and looping).
    last_msg = messages[-1]
    is_fallback = getattr(
        last_msg, "type", ""
    ) == "human" and "Web Search Fallback Context" in str(last_msg.content)
    is_after_tool = (
        getattr(last_msg, "type", "") == "tool"
        or last_msg.__class__.__name__ == "ToolMessage"
    )

    if is_fallback or is_after_tool:
        llm_with_tools = llm
    else:
        tools_list = await get_tools(tool_settings)
        llm_with_tools = llm.bind_tools(tools_list, parallel_tool_calls=False)

    MAX_RETRIES = 3
    response = None
    for attempt in range(MAX_RETRIES):
        try:
            response = await llm_with_tools.ainvoke(modified_messages)
            break
        except Exception as e:  # noqa: BLE001
            import logging

            logging.getLogger(__name__).warning(
                f"Tool invocation crashed (Attempt {attempt + 1}/{MAX_RETRIES}) for {effective_model}: {e}"
            )
            if attempt < MAX_RETRIES - 1:
                # Add the error to the context so the model can try to correct itself
                modified_messages.append(
                    AIMessage(
                        content="[I attempted to use a tool but generated invalid syntax.]"
                    )
                )
                modified_messages.append(
                    HumanMessage(
                        content=f"Your previous tool call failed with error: {e}. Please strictly follow the required JSON tool call format and try again."
                    )
                )
            else:
                logging.getLogger(__name__).warning(
                    "Max retries reached. Falling back to llm without tools."
                )
                response = await llm.ainvoke(modified_messages)
                break

    # Inject the model name into the response so it gets saved to history and sent to frontend
    response.additional_kwargs["model_name"] = effective_model

    metrics: dict[str, Any] = {
        "generation_seconds": round(time.perf_counter() - started_at, 3),
        # Pass embeddings into metrics so _finalize_metrics can compute cosine retrieval_relevance.
        # These are popped inside _finalize_metrics and never sent to the frontend.
        "query_embedding": state.get("query_embedding"),
        "context_embedding": state.get("context_embedding"),
    }
    if state.get("calculate_grounding"):
        from backend.evaluation.grounding import evaluate_groundedness

        grounding_score = evaluate_groundedness(
            response.content,
            state.get("retrieved_context", ""),
            api_key=effective_api_key,
            model_name=effective_model,
        )
        metrics["grounding_score"] = (
            round(grounding_score, 3) if grounding_score is not None else None
        )

    response.additional_kwargs["metrics"] = _finalize_metrics(metrics)
    return {"messages": [response]}


async def execute_tools(state: AgentState):
    """The Tool execution node that runs DB queries and merges them."""
    from backend.mcp_server.tool_dispatch import execute_tools_internal

    messages = state["messages"]
    tenant_id = state["tenant_id"]

    last_message = messages[-1]
    tool_messages = []

    context_str, merged = await execute_tools_internal(
        last_message.tool_calls, tenant_id, state.get("tool_settings") or {}
    )

    query_emb = None
    context_emb = None
    if state.get("calculate_grounding"):
        from backend.ingestion.chunk_embed import embed_text as _embed_text

        user_query = next(
            (
                m.content
                for m in reversed(messages)
                if getattr(m, "type", "") in ("human", "user")
                or m.__class__.__name__ == "HumanMessage"
            ),
            "",
        )
        try:
            loop = asyncio.get_running_loop()
            query_emb = (
                await loop.run_in_executor(None, _embed_text, user_query)
                if user_query
                else None
            )
            context_emb = (
                await loop.run_in_executor(None, _embed_text, context_str)
                if context_str and context_str != "No results found."
                else None
            )
        except Exception as e:  # noqa: BLE001
            logger.warning("Failed to generate embedding for context: %s", repr(e))
            import sentry_sdk
            sentry_sdk.capture_exception(e)

    for tool_call in last_message.tool_calls:
        tool_messages.append(
            ToolMessage(
                content=f"Here is the context retrieved from the database:\\n{context_str}\\n\\n",
                tool_call_id=tool_call["id"],
                artifact=[
                    {
                        "id": getattr(h, "id", ""),
                        "payload": getattr(h, "payload", {}),
                        "sources": getattr(h, "sources", []),
                    }
                    for h in merged
                ],
            )
        )

    return {
        "messages": tool_messages,
        "retrieved_context": context_str,
        "query_embedding": query_emb,
        "context_embedding": context_emb,
    }


def should_continue(state: AgentState) -> str:
    """Router that determines if we need to call tools or if we are done."""
    messages = state["messages"]
    last_message = messages[-1]

    # If the LLM made a tool call, route to tools
    if last_message.tool_calls:
        return "tools"

    # Otherwise, we are done
    return END


def _apply_observability_settings(tool_settings: dict | None):
    if not tool_settings:
        return

    obs = tool_settings.get("observability", {})
    enabled = obs.get("langsmith_enabled", False)
    api_key = obs.get("langsmith_api_key", "")

    if enabled and api_key:
        os.environ["LANGCHAIN_TRACING_V2"] = "true"
        os.environ["LANGCHAIN_API_KEY"] = api_key
        os.environ["LANGCHAIN_PROJECT"] = "Veraxi"
    else:
        os.environ["LANGCHAIN_TRACING_V2"] = "false"


def route_evaluation(state: AgentState) -> str:
    """Routes based on the evaluation grade."""
    score = state.get("context_relevance", "yes")
    if score == "yes":
        return "agent"
    return "web_search"


async def web_search_fallback(state: AgentState):
    """Fallback node that triggers SearXNG if the database context is insufficient."""
    logger.info("CRAG: Triggering Web Search Fallback via SearXNG...")
    messages = state["messages"]
    user_query = next(
        (
            m.content
            for m in reversed(messages)
            if getattr(m, "type", "") == "human"
            or getattr(m, "type", "") == "user"
            or m.__class__.__name__ == "HumanMessage"
        ),
        messages[0].content,
    )

    config = get_config()
    search_url = config.searxng_url

    # Apply override from tool_settings if available
    tool_settings = state.get("tool_settings") or {}
    web_settings = tool_settings.get("web_search") or {}
    if web_settings.get("provider") == "SearXNG" and web_settings.get("searxng_url"):
        search_url = web_settings.get("searxng_url")

    try:
        # Perform asynchronous web search in thread
        loop = asyncio.get_running_loop()

        def _do_search():
            req = urllib.request.Request(
                f"{search_url}?q={urllib.parse.quote(user_query)}&format=json&language=all",
                headers={"User-Agent": "VeraxiAgent/1.0"},
            )
            with urllib.request.urlopen(req) as response:
                return json.loads(response.read().decode())

        data = await loop.run_in_executor(None, _do_search)

        results = data.get("results", [])
        web_context = []
        for i, res in enumerate(results[:10], 1):  # Top 10 hits
            web_context.append(
                f"[Web Result {i} ({res.get('url')})]: {res.get('content')}"
            )

        context_str = "\n".join(web_context)
        if not context_str:
            context_str = "No web search results found."

        grounding_message = HumanMessage(
            content=(
                f"Web Search Fallback Context:\n{context_str}\n\n"
                f"Please provide your final answer based strictly on the above context."
            )
        )
        return {"messages": [grounding_message], "retrieved_context": context_str}
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"CRAG Web Search failed: {e}")
        return {
            "messages": [
                HumanMessage(
                    content="Web search fallback failed. Please provide your final answer based on your internal knowledge or admit lack of context."
                )
            ]
        }


class GradeDocuments(BaseModel):
    """Binary score for relevance check on retrieved documents."""

    binary_score: str = Field(
        description="Documents are relevant to the question, 'yes' or 'no'"
    )


async def evaluate_context(state: AgentState):
    """Grades the context retrieved by tools against the user's query."""
    messages = state["messages"]

    # Find the most recent human query
    user_query = next(
        (
            m.content
            for m in reversed(messages)
            if getattr(m, "type", "") == "human"
            or getattr(m, "type", "") == "user"
            or m.__class__.__name__ == "HumanMessage"
        ),
        messages[0].content,
    )

    context_str = state.get("retrieved_context", "")

    # If the DB returned nothing or is empty
    if not context_str or "No results found." in context_str:
        logger.info("CRAG: No DB results found. Grading as irrelevant.")
        return {"context_relevance": "no"}

    logger.info("CRAG: Evaluating retrieved context...")

    config = get_config()

    effective_model = _request_model.get() or config.llm_model_name
    llm_args = config.get_llm_client_args(model_name=effective_model)
    effective_api_key = _request_api_key.get() or config.llm_api_key
    effective_base_url = _request_base_url.get() or None

    # We can just reuse _create_chat_llm if we want, or initialize directly.
    # _create_chat_llm handles kwargs like api_key, base_url.
    llm = _create_chat_llm(effective_model, effective_api_key, effective_base_url)
    llm = llm.bind(tags=["crag_evaluator"])
    if effective_api_key:
        llm_args["api_key"] = effective_api_key

    llm = ChatOpenAI(
        model=effective_model, temperature=0, tags=["crag_evaluator"], **llm_args
    )
    structured_llm_grader = llm.with_structured_output(
        GradeDocuments, method="function_calling"
    )

    system = """You are a grader assessing relevance of a retrieved document to a user question. \n 
    It does not need to be a stringent test. The goal is to filter out erroneous retrievals. \n
    If the document contains keyword(s) or semantic meaning related to the user question, grade it as relevant. \n
    Give a binary score 'yes' or 'no' score to indicate whether the document is relevant to the question."""

    grade_prompt = f"{system}\n\nRetrieved document: \n\n {context_str} \n\n User question: {user_query}"

    try:
        res = await structured_llm_grader.ainvoke(grade_prompt)
        score = res.binary_score
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"CRAG Evaluation failed: {e}. Defaulting to 'no'.")
        score = "no"

    logger.info(f"CRAG: Graded context relevance as '{score}'")
    return {"context_relevance": score}


