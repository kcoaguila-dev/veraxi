import json
import logging
import time
import uuid
from collections.abc import AsyncGenerator
from typing import Any

from langchain_core.messages import (
    AIMessageChunk,
    BaseMessage,
    HumanMessage,
    SystemMessage,
)
from langgraph.checkpoint.memory import MemorySaver
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

from backend.config import get_config
from backend.mcp_server.formatter import (
    _extract_metrics_from_state,
    _sanitize_thread_title,
)
from backend.mcp_server.orchestrator import (
    _apply_observability_settings,
    _create_chat_llm,
    _get_workflow,
    _request_api_key,
    _request_base_url,
    _request_model,
)
from backend.mcp_server.think_parser import ThinkParseResult, ThinkTagStreamParser
from backend.prompts import TITLE_GENERATION_PROMPT

logger = logging.getLogger(__name__)

_FALLBACK_MEMORY_SAVER = MemorySaver()
_POSTGRES_SETUP_DONE: set[str] = set()


async def setup_postgres_checkpointer_once(
    memory: AsyncPostgresSaver, postgres_url: str
) -> None:
    """Ensure setup() is called only once per connection string to prevent DDL migration on every request."""
    if postgres_url not in _POSTGRES_SETUP_DONE:
        await memory.setup()
        _POSTGRES_SETUP_DONE.add(postgres_url)


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
    response = await llm.ainvoke(
        [
            SystemMessage(content=TITLE_GENERATION_PROMPT),
            HumanMessage(content=question),
        ]
    )
    return _sanitize_thread_title(response.content)


def _completion_response_text(content) -> str:
    """Normalize an LLM response payload to plain text.

    Chat models return either a string or a list of content blocks
    (``{"type": "text", "text": ...}`` dicts / plain strings); the
    in-artifact AI bridge contract is a single string.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and isinstance(block.get("text"), str):
                parts.append(block["text"])
        return "".join(parts)
    return str(content)


async def run_single_completion(
    prompt: str,
    system: str | None = None,
    model_override: str | None = None,
    api_key_override: str | None = None,
    base_url_override: str | None = None,
    max_tokens: int | None = None,
) -> str:
    """Run one non-streaming completion and return its text.

    The single-shot sibling of :func:`generate_chat_title`, used by
    the in-artifact AI bridge (``window.veraxi.complete``): same
    BYOK/model override flow, but the caller's own system prompt and
    token budget instead of the title prompt. Raises whatever the
    provider raises — callers translate failures for their surface.
    """
    if base_url_override and not api_key_override:
        raise ValueError("api_key_override is required when base_url_override is set")
    config = get_config()
    effective_model = model_override or config.llm_model_name
    effective_api_key = api_key_override or config.llm_api_key
    llm = _create_chat_llm(effective_model, effective_api_key, base_url_override)
    if max_tokens is not None:
        llm = llm.bind(max_tokens=max_tokens)
    messages: list[BaseMessage] = []
    if system:
        messages.append(SystemMessage(content=system))
    messages.append(HumanMessage(content=prompt))
    response = await llm.ainvoke(messages)
    return _completion_response_text(response.content)


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
) -> str | tuple[str, str] | tuple[str, str, dict]:
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

    logger.info(
        f"Starting async LangGraph run for thread_id={thread_id} (temporary={is_temporary})"
    )

    workflow = _get_workflow()

    try:
        if is_temporary:
            app = workflow.compile()
            final_state = await app.ainvoke(initial_state, config=config)
        elif not config_obj.postgres_url:
            app = workflow.compile(checkpointer=_FALLBACK_MEMORY_SAVER)
            final_state = await app.ainvoke(initial_state, config=config)
        else:
            # Run the graph asynchronously using context manager for memory
            async with AsyncPostgresSaver.from_conn_string(
                config_obj.postgres_url
            ) as memory:
                await setup_postgres_checkpointer_once(memory, config_obj.postgres_url)
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


TOOL_LABELS: dict[str, str] = {
    "mcp_query_graph": "Query Knowledge Graph",
    "mcp_web_search": "Search Live Web",
    "mcp_search_vectors": "Search Vector Memory",
    "mcp_ephemeral_web_rag": "Live Web Ingestion & Retrieval",
    "mcp_agentic_debate": "Deep Research Multi-Agent Debate",
    "mcp_dynamic_web_graph": "Dynamic Graph Construction",
    "mcp_run_code": "Python Code Interpreter",
    "mcp_evaluate_grounding": "Verify Grounding & Veracity",
    "mcp_get_stats": "Inspect Graph Telemetry",
    "mcp_get_graph_schema": "Inspect Graph Schema",
    "mcp_run_community_detection": "Run Community Detection",
    "mcp_ingest_document": "Ingest Document",
    "code_read_file": "Read Repository File",
    "code_list_files": "Browse Repository Files",
    "code_symbol": "Inspect Code Symbol",
    "code_impact": "Analyze Code Impact",
    "code_overview": "Inspect Repository Overview",
    "github_get_file": "Read GitHub File",
    "github_search_code": "Search GitHub Code",
    "github_list_repos": "List GitHub Repositories",
}


def _get_tool_friendly_label(tool_name: str) -> str:
    """Returns a clean, human-readable tool label for UI and CLI displays."""
    if tool_name in TOOL_LABELS:
        return TOOL_LABELS[tool_name]
    clean = tool_name.replace("mcp_", "").replace("_", " ")
    return clean.title()


def _make_tool_summary(name: str, content: str, artifact: Any = None) -> str:
    """Generate a clean, high-veracity preview of tool output."""
    if isinstance(artifact, list) and artifact:
        return f"Retrieved {len(artifact)} evidence chunks from graph"
    if not content:
        return "Executed successfully"
    if content.startswith("Error:"):
        return content[:120]
    if "No results found" in content:
        return "No matching records found"
    lines = [line.strip() for line in str(content).splitlines() if line.strip()]
    if lines:
        preview = lines[0]
        return preview[:120] + ("..." if len(preview) > 120 else "")
    return "Executed successfully"


def _handle_chat_model_end(
    event: dict,
    tool_start_times: dict[str, float] | None = None,
    current_step: int = 1,
) -> list[dict]:
    if tool_start_times is None:
        tool_start_times = {}
    events = []
    msg = event.get("data", {}).get("output")
    if hasattr(msg, "tool_calls") and msg.tool_calls:
        for tc in msg.tool_calls:
            run_id = tc.get("id") or str(uuid.uuid4())
            name = tc.get("name", "tool")
            tool_start_times[run_id] = time.perf_counter()
            events.append(
                {
                    "event": "on_tool_start",
                    "name": name,
                    "label": _get_tool_friendly_label(name),
                    "step": current_step,
                    "run_id": run_id,
                    "data": {"input": tc.get("args", {})},
                }
            )
    return events


def _handle_chain_end_tools(
    event: dict,
    tool_start_times: dict[str, float] | None = None,
    current_step: int = 1,
) -> list[dict]:
    if tool_start_times is None:
        tool_start_times = {}
    events = []
    output = event.get("data", {}).get("output", {})
    if isinstance(output, dict) and "messages" in output:
        for m in output["messages"]:
            if hasattr(m, "tool_call_id") and m.tool_call_id:
                run_id = m.tool_call_id
                start_t = tool_start_times.pop(run_id, None)
                duration_ms = (
                    round((time.perf_counter() - start_t) * 1000)
                    if start_t is not None
                    else None
                )
                name = m.name or "tool"
                content_str = str(m.content or "")
                is_error = content_str.startswith("Error:")
                events.append(
                    {
                        "event": "on_tool_end",
                        "name": name,
                        "label": _get_tool_friendly_label(name),
                        "step": current_step,
                        "run_id": run_id,
                        "duration_ms": duration_ms,
                        "status": "error" if is_error else "success",
                        "summary": _make_tool_summary(
                            name, content_str, getattr(m, "artifact", None)
                        ),
                        "data": {
                            "output": m.content,
                            "artifact": getattr(m, "artifact", None),
                        },
                    }
                )
    return events


def _handle_chain_end_langgraph(
    event: dict, started_at: float | None = None
) -> list[dict]:
    events = []
    output_state = (
        event.get("data", {}).get("output") or event.get("data", {}).get("chunk") or {}
    )
    if isinstance(output_state, dict):
        metrics = dict(_extract_metrics_from_state(output_state) or {})
        if started_at:
            elapsed = round(time.perf_counter() - started_at, 2)
            metrics["generation_seconds"] = metrics.get("generation_seconds") or elapsed
            metrics["worked_for"] = f"{elapsed}s"
        if metrics:
            events.append({"event": "metadata", "data": {"metrics": metrics}})
    return events


def _reasoning_events_from_parse(
    parsed: ThinkParseResult, event: dict, chunk: Any
) -> list[dict]:
    """Convert a ``ThinkParseResult`` into SSE stream events."""
    out: list[dict] = []
    for r_delta in parsed.reasoning_deltas:
        out.append({"event": "on_reasoning_stream", "data": {"text": r_delta}})
    if parsed.reasoning_ended_ms is not None:
        out.append(
            {
                "event": "on_reasoning_end",
                "data": {
                    "duration_ms": parsed.reasoning_ended_ms,
                    "seconds": round(parsed.reasoning_ended_ms / 1000, 1),
                },
            }
        )
    for c_delta in parsed.content_deltas:
        chunk.content = c_delta
        out.append(event)
    return out


def _flush_think_parser(think_parser: ThinkTagStreamParser) -> list[dict]:
    """Flush trailing buffered characters and close any active reasoning block."""
    flushed = think_parser.flush()
    out: list[dict] = []
    for r_delta in flushed.reasoning_deltas:
        out.append({"event": "on_reasoning_stream", "data": {"text": r_delta}})
    if flushed.reasoning_ended_ms is not None:
        out.append(
            {
                "event": "on_reasoning_end",
                "data": {
                    "duration_ms": flushed.reasoning_ended_ms,
                    "seconds": round(flushed.reasoning_ended_ms / 1000, 1),
                },
            }
        )
    for c_delta in flushed.content_deltas:
        out.append(
            {
                "event": "on_chat_model_stream",
                "data": {"chunk": AIMessageChunk(content=c_delta)},
            }
        )
    return out


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
    Executes the LangGraph state machine and yields raw astream_events
    enriched with real-time steps, tool durations, and reasoning traces.
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

        logger.info(
            f"Starting async streaming LangGraph run for thread_id={thread_id} (temporary={is_temporary})"
        )
        workflow = _get_workflow()

        async def _process_stream(stream):
            tool_start_times: dict[str, float] = {}
            current_step = 1
            think_parser = ThinkTagStreamParser()
            called_tools: list[str] = []
            started_at = time.perf_counter()

            # Step 1: Initial research & tool determination
            yield {
                "event": "on_step_start",
                "step": current_step,
                "name": "Planning & Discovery",
                "description": "Analyzing intent and selecting domain tools...",
            }

            async for event in stream:
                if "crag_evaluator" in event.get("tags", []):  # noqa: SIM102
                    # We ignore stream events and end events for the internal CRAG evaluator
                    # so that it doesn't accidentally emit 'GradeDocuments' tool calls to the UI.
                    if event["event"] in [
                        "on_chat_model_stream",
                        "on_chat_model_end",
                        "on_tool_start",
                        "on_tool_end",
                    ]:
                        continue

                # Parse reasoning / <think> blocks (DeepSeek-R1 / QwQ / Qwen3 / Ollama)
                if event["event"] == "on_chat_model_stream":
                    chunk = event.get("data", {}).get("chunk")
                    if hasattr(
                        chunk, "additional_kwargs"
                    ) and chunk.additional_kwargs.get("reasoning_content"):
                        parsed = think_parser.feed_explicit_reasoning(
                            chunk.additional_kwargs["reasoning_content"]
                        )
                        for sse_ev in _reasoning_events_from_parse(parsed, event, chunk):
                            yield sse_ev
                        continue
                    if hasattr(chunk, "content") and isinstance(chunk.content, str):
                        parsed = think_parser.feed_content(chunk.content)
                        for sse_ev in _reasoning_events_from_parse(parsed, event, chunk):
                            yield sse_ev
                        continue

                if event["event"] == "on_chat_model_end":
                    for sse_ev in _flush_think_parser(think_parser):
                        yield sse_ev
                    tool_events = _handle_chat_model_end(
                        event, tool_start_times, current_step
                    )
                    # Loop detection: detect repeated tool calls with identical args
                    loop_detected = False
                    for te in tool_events:
                        t_fp = f"{te['name']}:{json.dumps(te['data'].get('input', {}), sort_keys=True)}"
                        if called_tools.count(t_fp) >= 2:
                            logger.warning(
                                "Loop detector caught runaway tool repetition: %s", t_fp
                            )
                            loop_detected = True
                            break
                        called_tools.append(t_fp)
                        yield te

                    if loop_detected:
                        yield {
                            "event": "on_tool_end",
                            "name": "loop_guard",
                            "label": "Runaway Loop Guard",
                            "step": current_step,
                            "run_id": str(uuid.uuid4()),
                            "duration_ms": 0,
                            "status": "warning",
                            "summary": "Detected repetitive tool pattern; proceeding to synthesis to prevent timeout",
                            "data": {
                                "output": "Tool execution paused by loop guard to prevent timeout."
                            },
                        }

                if event["event"] == "on_chain_end" and event.get("name") in [
                    "execute_tools",
                    "tools",
                ]:
                    for e in _handle_chain_end_tools(
                        event, tool_start_times, current_step
                    ):
                        yield e

                    # Advance to synthesis step once tools complete
                    current_step += 1
                    yield {
                        "event": "on_step_start",
                        "step": current_step,
                        "name": "Answer Synthesis",
                        "description": "Synthesizing answer grounded in retrieved knowledge...",
                    }

                # Emit metrics as each agent step finishes so mid-turn failures
                # (e.g. rate limits on a later step) still surface completed usage.
                if (
                    event["event"] == "on_chain_end"
                    and event.get("name") in ("agent", "LangGraph")
                ):
                    for e in _handle_chain_end_langgraph(event, started_at):
                        yield e

                yield event

            for sse_ev in _flush_think_parser(think_parser):
                yield sse_ev

        if is_temporary:
            app = workflow.compile()
            async for evt in _process_stream(
                app.astream_events(initial_state, config=config, version="v2")
            ):
                yield evt
        elif not config_obj.postgres_url:
            app = workflow.compile(checkpointer=_FALLBACK_MEMORY_SAVER)
            async for evt in _process_stream(
                app.astream_events(initial_state, config=config, version="v2")
            ):
                yield evt
        else:
            async with AsyncPostgresSaver.from_conn_string(
                config_obj.postgres_url
            ) as memory:
                await setup_postgres_checkpointer_once(memory, config_obj.postgres_url)
                app = workflow.compile(checkpointer=memory)
                async for evt in _process_stream(
                    app.astream_events(initial_state, config=config, version="v2")
                ):
                    yield evt
    finally:
        _request_api_key.reset(token_api)
        _request_base_url.reset(token_base_url)
        _request_model.reset(token_model)
