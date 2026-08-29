import os
import logging
import sentry_sdk
import json
import time
import re
from contextvars import ContextVar
from typing import Tuple, List, Any, TypedDict, Annotated, Sequence
from langchain_openai import ChatOpenAI
import asyncio
import urllib.request
import urllib.parse
from pydantic import BaseModel, Field
from langchain_core.messages import BaseMessage, HumanMessage, ToolMessage, AIMessage, SystemMessage
from langgraph.graph import StateGraph, START, END
from langgraph.graph.message import add_messages
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
import redis.asyncio as redis_async
from mcp.client.sse import sse_client
from mcp.client.session import ClientSession

_MCP_TOOL_CACHE = {}  # Cache tool schemas to avoid frequent handshakes

from backend.config import get_config
from backend.prompts import CHAT_SYSTEM_PROMPT, TITLE_GENERATION_PROMPT
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.retrieval.merge_rank import merge_rank

logger = logging.getLogger(__name__)

# Per-async-task context variable that carries the caller's API key for the
# duration of a single request — avoids mutating shared config.
_request_model: ContextVar[str | None] = ContextVar("_request_model", default=None)
_request_api_key: ContextVar[str | None] = ContextVar("_request_api_key", default=None)
_request_base_url: ContextVar[str | None] = ContextVar("_request_base_url", default=None)
_request_model: ContextVar[str | None] = ContextVar("_request_model", default=None)

# We will initialize the connection dynamically or just keep a global pool
_redis_conn = None
_app = None

def _get_workflow():
    workflow = StateGraph(AgentState)
    workflow.add_node("agent", call_model)
    workflow.add_node("tools", execute_tools)
    workflow.add_node("evaluate", evaluate_context)
    workflow.add_node("web_search", web_search_fallback)

    workflow.add_edge(START, "agent")
    workflow.add_conditional_edges("agent", should_continue, ["tools", END])
    workflow.add_edge("tools", "evaluate")
    workflow.add_conditional_edges("evaluate", route_evaluation, ["agent", "web_search"])
    workflow.add_edge("web_search", "agent")
    
    return workflow

class AgentState(TypedDict):
    messages: Annotated[Sequence[BaseMessage], add_messages]
    tenant_id: str
    context_relevance: str
    retrieved_context: str
    query_embedding: list[float] | None
    calculate_grounding: bool
    tool_settings: dict | None

async def get_tools(tool_settings: dict = None) -> list:
    config = get_config()
    
    # Default to disabled if settings are missing
    file_search_enabled = False
    web_search_enabled = False
    run_code_enabled = False
    skills_enabled = False
    
    mcp_servers = []
    
    if tool_settings:
        file_search_enabled = tool_settings.get("file_search_enabled", False)
        if "web_search" in tool_settings and "enabled" in tool_settings["web_search"]:
            web_search_enabled = tool_settings["web_search"]["enabled"]
        
        run_code_enabled = tool_settings.get("run_code_enabled", False)
        skills_enabled = tool_settings.get("skills_enabled", False)
        if skills_enabled:
            mcp_servers = tool_settings.get("mcp_servers", [])
            
    all_tools = []
    
    if file_search_enabled:
        all_tools.extend([
            {
                "type": "function",
                "function": {
                "name": "search_vectors",
                "description": "Search for semantically similar text chunks in the vector database.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query_text": {
                            "type": "string",
                            "description": "The text to search for."
                        },
                        "limit": {
                            "type": ["integer", "string"],
                            "description": f"Maximum number of results to return (default {config.default_search_limit})."
                        }
                    },
                    "required": ["query_text"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "query_graph",
                "description": "Query the knowledge graph starting from a specific entity.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "entity_name": {
                            "type": "string",
                            "description": "The name of the entity to start the traversal from."
                        },
                        "max_hops": {
                            "type": "integer",
                            "description": f"Maximum number of relationship hops (default {config.default_max_hops})."
                        }
                    },
                    "required": ["entity_name"]
                }
            }
        }
    ])
        
    if web_search_enabled:
        all_tools.append({
            "type": "function",
            "function": {
                "name": "web_search",
                "description": "Search the internet for real-time information, news, and external knowledge.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "The search query."
                        }
                    },
                    "required": ["query"]
                }
            }
        })
        
    if run_code_enabled:
        all_tools.append({
            "type": "function",
            "function": {
                "name": "run_python_code",
                "description": "Execute Python code in a secure sandbox and return the stdout and stderr.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "code": {
                            "type": "string",
                            "description": "The Python code to execute."
                        }
                    },
                    "required": ["code"]
                }
            }
        })
        
    if skills_enabled and mcp_servers:
        for server in mcp_servers:
            server_name = server.get("name", "unknown")
            url = server.get("url", "")
            is_enabled = server.get("enabled", True)
            
            if not url or not is_enabled:
                continue
            
            if url in _MCP_TOOL_CACHE:
                all_tools.extend(_MCP_TOOL_CACHE[url])
                continue
            
            try:
                async with sse_client(url) as (read, write):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        tools_res = await session.list_tools()
                        mapped_tools = []
                        for t in tools_res.tools:
                            mapped_tools.append({
                                "type": "function",
                                "function": {
                                    "name": f"mcp__{server_name}__{t.name}",
                                    "description": t.description or "MCP Dynamic Tool",
                                    "parameters": t.inputSchema or {"type": "object", "properties": {}}
                                }
                            })
                        _MCP_TOOL_CACHE[url] = mapped_tools
                        all_tools.extend(mapped_tools)
            except Exception as e:
                logger.error(f"Failed to fetch tools from MCP server {url}: {e}")
        
    return all_tools

def _execute_single_tool(tool_name: str, tool_input: dict, tenant_id: str, tool_settings: dict | None = None) -> Tuple[List[Any], List[Any]]:
    config = get_config()
    settings = tool_settings or {}
    
    if tool_name == "search_vectors":
        if not settings.get("file_search_enabled", False):
            class ErrorHit:
                def __init__(self):
                    self.id = "tool_err"
                    self.payload = {"error": "Tool search_vectors is currently disabled by the user."}
                    self.sources = ["System Error"]
            return [ErrorHit()], []
        limit = int(tool_input.get("limit", config.default_search_limit))
        return search_vectors(tool_input["query_text"], limit=limit, tenant_id=tenant_id), []
    elif tool_name == "query_graph":
        if not settings.get("file_search_enabled", False):
            return [], []
        max_hops = int(tool_input.get("max_hops", config.default_max_hops))
        return [], query_graph(tool_input["entity_name"], max_hops=max_hops, tenant_id=tenant_id)
    elif tool_name == "web_search":
        web_search = settings.get("web_search", {})
        if not web_search.get("enabled", False):
            class ErrorHit:
                def __init__(self):
                    self.id = "tool_err"
                    self.payload = {"error": "Tool web_search is currently disabled by the user."}
                    self.sources = ["System Error"]
            return [ErrorHit()], []
            
        from backend.mcp_server.tools.web_search import mcp_web_search
        results = mcp_web_search(tool_input["query"], tool_settings=tool_settings)
        
        import uuid
        class WebHit:
            def __init__(self, res):
                self.id = str(uuid.uuid4())
                self.payload = {
                    "text": res.get("content", ""),
                    "snippet": res.get("snippet", ""),
                    "title": res.get("title", ""),
                    "url": res.get("url", "")
                }
                self.sources = [res.get("url", "web")]
                
        return [WebHit(r) for r in results], []
    elif tool_name == "run_python_code":
        import requests
        try:
            resp = requests.post(
                config.code_interpreter_url,
                json={"code": tool_input["code"]},
                timeout=15
            )
            resp.raise_for_status()
            data = resp.json()
            class CodeHit:
                def __init__(self, res):
                    self.id = "code_exec"
                    self.payload = {"stdout": res.get("stdout", ""), "stderr": res.get("stderr", ""), "exit_code": res.get("exit_code")}
                    self.sources = ["Python Sandbox"]
            return [CodeHit(data)], []
        except Exception as e:
            class ErrorHit:
                def __init__(self, err):
                    self.id = "code_err"
                    self.payload = {"error": str(err)}
                    self.sources = ["Python Sandbox Error"]
            return [ErrorHit(e)], []
    elif tool_name == "get_current_time":
        import datetime
        class TimeHit:
            def __init__(self):
                self.id = "time"
                self.payload = {"current_utc_time": datetime.datetime.now(datetime.timezone.utc).isoformat()}
                self.sources = ["System Clock"]
        return [TimeHit()], []
    elif tool_name == "fetch_url":
        import requests
        try:
            resp = requests.get(tool_input["url"], timeout=10)
            resp.raise_for_status()
            class UrlHit:
                def __init__(self, text, url):
                    self.id = "url"
                    self.payload = {"content": text[:2000]} # Truncate to save tokens
                    self.sources = [url]
            return [UrlHit(resp.text, tool_input["url"])], []
        except Exception as e:
            class UrlErrorHit:
                def __init__(self, err, url):
                    self.id = "url_err"
                    self.payload = {"error": str(err)}
                    self.sources = [url]
            return [UrlErrorHit(e, tool_input["url"])], []
            
    return [], []

def _build_context_string(merged_results: List[Any]) -> str:
    """Build a formatted context string from fused results."""
    context_parts = []
    for i, res in enumerate(merged_results, 1):
        source_info = " and ".join(res.sources)
        payload_str = str(res.payload)
        context_parts.append(f"[Result {i} (from {source_info})]: {payload_str}")

    return "\n".join(context_parts)


def _extract_metrics_from_state(state: dict) -> dict[str, Any]:
    messages = state.get("messages") or []
    if not messages:
        return {}

    last_message = messages[-1]
    additional_kwargs = getattr(last_message, "additional_kwargs", {}) or {}
    metrics = additional_kwargs.get("metrics")
    if isinstance(metrics, dict):
        return metrics
    return {}


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    """Compute cosine similarity between two embedding vectors."""
    import numpy as np
    va = np.array(a, dtype=float)
    vb = np.array(b, dtype=float)
    norm_a = np.linalg.norm(va)
    norm_b = np.linalg.norm(vb)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(va, vb) / (norm_a * norm_b))




def _finalize_metrics(metrics: dict[str, Any]) -> dict[str, Any]:
    """Derive display-ready metric fields from raw telemetry collected during generation."""
    finalized = dict(metrics)

    # --- Context Adherence (grounding) ---
    grounding_score = finalized.get("grounding_score")
    if isinstance(grounding_score, (int, float)):
        finalized["context_adherence"] = round(float(grounding_score), 3)

    # --- Retrieval Relevance (cosine similarity, query ↔ context) ---
    retrieval_relevance: float | None = None
    query_emb = finalized.pop("query_embedding", None)
    context_emb = finalized.pop("context_embedding", None)
    if isinstance(query_emb, list) and isinstance(context_emb, list):
        retrieval_relevance = round(
            max(0.0, min(1.0, _cosine_similarity(query_emb, context_emb))), 3
        )
        finalized["retrieval_relevance"] = retrieval_relevance

    # --- Confidence (mean of available scores) ---
    score_candidates = [
        value
        for value in [finalized.get("context_adherence"), retrieval_relevance]
        if isinstance(value, (int, float))
    ]
    if score_candidates:
        finalized["confidence"] = round(sum(score_candidates) / len(score_candidates), 3)

    # --- Precision (harmonic mean / F1 of adherence & relevance) ---
    adherence = finalized.get("context_adherence")
    if isinstance(adherence, (int, float)) and isinstance(retrieval_relevance, (int, float)):
        denom = float(adherence) + retrieval_relevance
        finalized["precision"] = (
            round((2 * float(adherence) * retrieval_relevance) / denom, 3) if denom > 0 else 0.0
        )

    return finalized

def _sanitize_thread_title(raw_title: str) -> str:
    """Normalize model output into a sidebar-safe thread title."""
    title = raw_title.strip().strip('"\'').strip()
    title = title.split("\n", 1)[0].strip()
    title = re.sub(r"\s*\([^)]*\)\s*$", "", title).strip()
    if len(title) > 60:
        title = title[:57] + "..."
    return title


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


async def generate_chat_title(
    question: str,
    api_key_override: str | None = None,
    base_url_override: str | None = None,
    model_override: str | None = None,
) -> str:
    """Generate a short thread title via a direct LLM call (no agent graph)."""
    config = get_config()
    effective_model = model_override or config.llm_model_name
    effective_api_key = api_key_override or config.llm_api_key
    llm = _create_chat_llm(effective_model, effective_api_key, base_url_override)
    response = await llm.ainvoke([
        SystemMessage(content=TITLE_GENERATION_PROMPT),
        HumanMessage(content=question),
    ])
    return _sanitize_thread_title(response.content)


def _prepend_system_messages(
    messages: Sequence[BaseMessage],
    extra_system_messages: list[SystemMessage] | None = None,
) -> list[BaseMessage]:
    """Inject chat-wide system instructions without persisting them to thread state."""
    system_messages = [SystemMessage(content=CHAT_SYSTEM_PROMPT)]
    if extra_system_messages:
        system_messages.extend(extra_system_messages)

    modified_messages = list(messages)
    for system_message in reversed(system_messages):
        modified_messages.insert(0, system_message)
    return modified_messages


# --- LangGraph Nodes ---

async def call_model(state: AgentState):
    """The AI Agent node that decides what to do."""
    messages = state["messages"]
    started_at = time.perf_counter()
    
    config = get_config()
    
    effective_model = _request_model.get() or config.llm_model_name
    
    # Inherit base args (including the gemini url injection if applicable)
    llm_args = config.get_llm_client_args(model_name=effective_model)
    
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
        extra_system_messages.append(SystemMessage(content=(
            "Artifacts are enabled. You can generate UI components, code snippets, or diagrams for the user to view. "
            "To generate an artifact, output a markdown block with the language set to the artifact type, e.g. "
            "```html\n<h1>Hello</h1>\n``` or ```mermaid\ngraph TD; A-->B;\n```. "
            "Make sure your artifacts are entirely self-contained."
        )))

    modified_messages = _prepend_system_messages(messages, extra_system_messages)
    
    # Determine if we should bind tools. We do not bind tools if we are executing a fallback, 
    # OR if we just received a ToolMessage (to prevent the LLM from hallucinating more tool calls and looping).
    last_msg = messages[-1]
    is_fallback = getattr(last_msg, "type", "") == "human" and "Web Search Fallback Context" in str(last_msg.content)
    is_after_tool = getattr(last_msg, "type", "") == "tool" or last_msg.__class__.__name__ == "ToolMessage"
    
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
        except Exception as e:
            import logging
            logging.getLogger(__name__).warning(f"Tool invocation crashed (Attempt {attempt + 1}/{MAX_RETRIES}) for {effective_model}: {e}")
            if attempt < MAX_RETRIES - 1:
                # Add the error to the context so the model can try to correct itself
                modified_messages.append(AIMessage(content="[I attempted to use a tool but generated invalid syntax.]"))
                modified_messages.append(HumanMessage(content=f"Your previous tool call failed with error: {e}. Please strictly follow the required JSON tool call format and try again."))
            else:
                logging.getLogger(__name__).warning(f"Max retries reached. Falling back to llm without tools.")
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
        metrics["grounding_score"] = round(grounding_score, 3) if grounding_score is not None else None

    response.additional_kwargs["metrics"] = _finalize_metrics(metrics)
    return {"messages": [response]}


async def _execute_mcp_tool(tool_name: str, tool_input: dict, tool_settings: dict) -> Tuple[List[Any], List[Any]]:
    # format is mcp__{server_name}__{actual_tool_name}
    parts = tool_name.split("__", 2)
    if len(parts) != 3:
        return [], []
    server_name = parts[1]
    actual_tool_name = parts[2]
    
    mcp_servers = tool_settings.get("mcp_servers", [])
    url = next((s.get("url") for s in mcp_servers if s.get("name") == server_name), None)
    if not url:
        return [], []
        
    try:
        async with sse_client(url) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool(actual_tool_name, tool_input)
                
                class McpHit:
                    def __init__(self, res):
                        self.id = "mcp_tool"
                        self.payload = {"content": str(res)}
                        self.sources = [f"MCP Server ({server_name})"]
                        
                return [McpHit(result)], []
    except Exception as e:
        logger.error(f"Failed to execute MCP tool {tool_name} on {url}: {e}")
        class McpErrorHit:
            def __init__(self, err):
                self.id = "mcp_err"
                self.payload = {"error": str(err)}
                self.sources = [f"MCP Server ({server_name})"]
        return [McpErrorHit(e)], []

async def execute_tools(state: AgentState):
    """The Tool execution node that runs DB queries and merges them."""
    messages = state["messages"]
    tenant_id = state["tenant_id"]
    
    # The last message is the AIMessage containing tool calls
    last_message = messages[-1]
    
    tool_messages = []
    vector_hits = []
    graph_hits = []
    
    for tool_call in last_message.tool_calls:
        tool_name = tool_call["name"]
        tool_input = tool_call["args"]
        tool_call_id = tool_call["id"]
        
        logger.info(f"LangGraph Agent called tool: {tool_name} with args: {tool_input}")
        
        if tool_name.startswith("mcp__"):
            v_hits, g_hits = await _execute_mcp_tool(tool_name, tool_input, state.get("tool_settings") or {})
        else:
            # Run synchronous DB calls in threadpool
            loop = asyncio.get_running_loop()
            v_hits, g_hits = await loop.run_in_executor(None, _execute_single_tool, tool_name, tool_input, tenant_id, state.get("tool_settings"))
        
        vector_hits.extend(v_hits)
        graph_hits.extend(g_hits)
        
    # Merge and rank the results
    merged = merge_rank(vector_hits, graph_hits)
    context_str = _build_context_string(merged)

    if not context_str:
        context_str = "No results found."

    query_emb = None
    context_emb = None
    if state.get("calculate_grounding"):
        # Compute context embedding now while we already have the retrieved text,
        # so _finalize_metrics can later derive a cosine-similarity retrieval_relevance
        # without an extra embed_text() call at response time.
        from backend.ingestion.chunk_embed import embed_text as _embed_text
        user_query = next(
            (m.content for m in reversed(messages)
             if getattr(m, "type", "") in ("human", "user") or m.__class__.__name__ == "HumanMessage"),
            "",
        )
        try:
            loop = asyncio.get_running_loop()
            query_emb = await loop.run_in_executor(None, _embed_text, user_query) if user_query else None
            context_emb = await loop.run_in_executor(None, _embed_text, context_str) if context_str and context_str != "No results found." else None
        except Exception:
            pass

    # We must satisfy LangChain's ToolMessage requirement by putting the results directly in it.
    # Since parallel_tool_calls=False, there should only be one tool call, but we handle multiple just in case.
    for tool_call in last_message.tool_calls:
        tool_messages.append(
            ToolMessage(
                content=f"Here is the context retrieved from the database:\n{context_str}\n\n",
                tool_call_id=tool_call["id"],
                artifact=[{"id": getattr(h, "id", ""), "payload": getattr(h, "payload", {}), "sources": getattr(h, "sources", [])} for h in merged]
            )
        )

    return {
        "messages": tool_messages,
        "retrieved_context": context_str,
        "query_embedding": query_emb,
        "context_embedding": context_emb,
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
    user_query = next((m.content for m in reversed(messages) if getattr(m, "type", "") == "human" or getattr(m, "type", "") == "user" or m.__class__.__name__ == "HumanMessage"), messages[0].content)
    
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
        
    llm = ChatOpenAI(model=effective_model, temperature=0, tags=["crag_evaluator"], **llm_args)
    structured_llm_grader = llm.with_structured_output(GradeDocuments, method="function_calling")
    
    system = """You are a grader assessing relevance of a retrieved document to a user question. \n 
    It does not need to be a stringent test. The goal is to filter out erroneous retrievals. \n
    If the document contains keyword(s) or semantic meaning related to the user question, grade it as relevant. \n
    Give a binary score 'yes' or 'no' score to indicate whether the document is relevant to the question."""
    
    grade_prompt = f"{system}\n\nRetrieved document: \n\n {context_str} \n\n User question: {user_query}"
    
    try:
        res = await structured_llm_grader.ainvoke(grade_prompt)
        score = res.binary_score
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"CRAG Evaluation failed: {e}. Defaulting to 'no'.")
        score = "no"
        
    logger.info(f"CRAG: Graded context relevance as '{score}'")
    return {"context_relevance": score}

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
    user_query = next((m.content for m in reversed(messages) if getattr(m, "type", "") == "human" or getattr(m, "type", "") == "user" or m.__class__.__name__ == "HumanMessage"), messages[0].content)
    
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
                headers={'User-Agent': 'VeraxiAgent/1.0'}
            )
            with urllib.request.urlopen(req) as response:
                return json.loads(response.read().decode())
                
        data = await loop.run_in_executor(None, _do_search)
        
        results = data.get("results", [])
        web_context = []
        for i, res in enumerate(results[:10], 1): # Top 10 hits
            web_context.append(f"[Web Result {i} ({res.get('url')})]: {res.get('content')}")
            
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
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"CRAG Web Search failed: {e}")
        return {"messages": [HumanMessage(content="Web search fallback failed. Please provide your final answer based on your internal knowledge or admit lack of context.")]}


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


async def answer_question(
    question: str,
    tenant_id: str = "default",
    thread_id: str = "default",
    return_context: bool = False,
    return_metrics: bool = False,
    is_temporary: bool = False,
    api_key_override: str | None = None,
    base_url_override: str | None = None,
    model_override: str | None = None,
    calculate_grounding: bool = False,
    tool_settings: dict | None = None,
) -> str | Tuple[str, str] | Tuple[str, str, dict]:
    """
    Executes the LangGraph state machine.
    Maintains conversation memory per thread_id, unless is_temporary is True.
    """
    # Set the per-request API key so call_model picks it up through the contextvar
    token_api = _request_api_key.set(api_key_override)
    token_base_url = _request_base_url.set(base_url_override)
    token_model = _request_model.set(model_override)
    _apply_observability_settings(tool_settings)
    
    config_obj = get_config()
    config = {"configurable": {"thread_id": thread_id}}
    
    initial_state = {
        "messages": [HumanMessage(content=question)],
        "tenant_id": tenant_id,
        "context_relevance": "",
        "retrieved_context": "",
        "query_embedding": None,
        "calculate_grounding": calculate_grounding,
        "tool_settings": tool_settings,
    }
    
    logger.info(f"Starting async LangGraph run for thread_id={thread_id} (temporary={is_temporary})")
    
    workflow = _get_workflow()
    
    try:
        if is_temporary:
            app = workflow.compile()
            final_state = await app.ainvoke(initial_state, config=config)
        else:
            # Run the graph asynchronously using context manager for memory
            async with AsyncPostgresSaver.from_conn_string(config_obj.postgres_url) as memory:
                await memory.setup()
                app = workflow.compile(checkpointer=memory)
                final_state = await app.ainvoke(initial_state, config=config)
    finally:
        # Always restore the contextvar regardless of success or failure
        _request_api_key.reset(token_api)
        _request_base_url.reset(token_base_url)
        _request_model.reset(token_model)
    
    # The final message is the AIMessage containing the answer
    final_message = final_state["messages"][-1]
    final_answer = final_message.content
    
    # Extract context cleanly from the dedicated state field
    context_str = final_state.get("retrieved_context", "")
    metrics = _extract_metrics_from_state(final_state)

    if return_context and return_metrics:
        return final_answer, context_str, metrics
    if return_context:
        return final_answer, context_str
    if return_metrics:
        return final_answer, metrics
    return final_answer


from typing import AsyncGenerator

def _handle_chat_model_end(event: dict) -> list[dict]:
    events = []
    msg = event.get("data", {}).get("output")
    if hasattr(msg, "tool_calls") and msg.tool_calls:
        for tc in msg.tool_calls:
            events.append({
                "event": "on_tool_start",
                "name": tc.get("name", "tool"),
                "run_id": tc.get("id", ""),
                "data": {"input": tc.get("args", {})}
            })
    return events


def _handle_chain_end_tools(event: dict) -> list[dict]:
    events = []
    output = event.get("data", {}).get("output", {})
    if isinstance(output, dict) and "messages" in output:
        for m in output["messages"]:
            if hasattr(m, "tool_call_id") and m.tool_call_id:
                events.append({
                    "event": "on_tool_end",
                    "name": m.name or "tool",
                    "run_id": m.tool_call_id,
                    "data": {
                        "output": m.content,
                        "artifact": getattr(m, "artifact", None)
                    }
                })
    return events


def _handle_chain_end_langgraph(event: dict) -> list[dict]:
    events = []
    output_state = event.get("data", {}).get("output") or event.get("data", {}).get("chunk") or {}
    if isinstance(output_state, dict):
        metrics = _extract_metrics_from_state(output_state)
        if metrics:
            events.append({"event": "metadata", "data": {"metrics": metrics}})
    return events


async def stream_answer_question(
    question: str,
    tenant_id: str = "default",
    thread_id: str = "default",
    is_temporary: bool = False,
    api_key_override: str | None = None,
    base_url_override: str | None = None,
    model_override: str | None = None,
    calculate_grounding: bool = False,
    tool_settings: dict | None = None,
) -> AsyncGenerator[dict, None]:
    """
    Executes the LangGraph state machine and yields raw astream_events.
    """
    # Set the per-request API key so call_model picks it up through the contextvar
    token_api = _request_api_key.set(api_key_override)
    token_base_url = _request_base_url.set(base_url_override)
    token_model = _request_model.set(model_override)
    _apply_observability_settings(tool_settings)
    try:
        config_obj = get_config()
        config = {"configurable": {"thread_id": thread_id}}
        
        initial_state = {
            "messages": [HumanMessage(content=question)],
            "tenant_id": tenant_id,
            "context_relevance": "",
            "retrieved_context": "",
            "query_embedding": None,
            "calculate_grounding": calculate_grounding,
            "tool_settings": tool_settings,
        }

        
        logger.info(f"Starting async streaming LangGraph run for thread_id={thread_id} (temporary={is_temporary})")
        workflow = _get_workflow()
        
        async def _process_stream(stream):
            async for event in stream:
                if "crag_evaluator" in event.get("tags", []):
                    # We ignore stream events and end events for the internal CRAG evaluator
                    # so that it doesn't accidentally emit 'GradeDocuments' tool calls to the UI.
                    if event["event"] in ["on_chat_model_stream", "on_chat_model_end", "on_tool_start", "on_tool_end"]:
                        continue
                    
                if event["event"] == "on_chat_model_end":
                    for e in _handle_chat_model_end(event):
                        yield e

                if event["event"] == "on_chain_end" and event.get("name") in ["execute_tools", "tools"]:
                    for e in _handle_chain_end_tools(event):
                        yield e

                if event["event"] == "on_chain_end" and event.get("name") == "LangGraph":
                    for e in _handle_chain_end_langgraph(event):
                        yield e
                yield event
        
        if is_temporary:
            app = workflow.compile()
            async for evt in _process_stream(app.astream_events(initial_state, config=config, version="v2")):
                yield evt
        else:
            async with AsyncPostgresSaver.from_conn_string(config_obj.postgres_url) as memory:
                await memory.setup()
                app = workflow.compile(checkpointer=memory)
                async for evt in _process_stream(app.astream_events(initial_state, config=config, version="v2")):
                    yield evt
    finally:
        _request_api_key.reset(token_api)
        _request_base_url.reset(token_base_url)
        _request_model.reset(token_model)
