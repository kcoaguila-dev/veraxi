import json
import logging
import os
import time
import uuid
from collections.abc import AsyncGenerator
from typing import Any

from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

from backend.config import get_config
from backend.mcp_server.formatter import (
    _extract_metrics_from_state,
    _sanitize_thread_title,
)
from backend.mcp_server.orchestrator import (
    _create_chat_llm,
    _get_workflow,
    _request_api_key,
    _request_base_url,
    _request_model,
)
from backend.prompts import TITLE_GENERATION_PROMPT

logger = logging.getLogger(__name__)


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
        else:
            # Run the graph asynchronously using context manager for memory
            async with AsyncPostgresSaver.from_conn_string(
                config_obj.postgres_url
            ) as memory:
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


TOOL_LABELS: dict[str, str] = {
    "mcp_query_graph": "Query Knowledge Graph",
    "mcp_web_search": "Search Live Web",
    "mcp_search_vectors": "Search Vector Memory",
    "mcp_deep_research": "Deep Research Synthesis",
    "mcp_ephemeral_web_rag": "Live Web Ingestion & Retrieval",
    "mcp_agentic_debate": "Deep Research Multi-Agent Debate",
    "mcp_dynamic_web_graph": "Dynamic Graph Construction",
    "mcp_run_code": "Python Code Interpreter",
    "mcp_evaluate_grounding": "Verify Grounding & Veracity",
    "mcp_get_stats": "Inspect Graph Telemetry",
    "mcp_get_graph_schema": "Inspect Graph Schema",
    "mcp_run_community_detection": "Run Community Detection",
    "mcp_ingest_document": "Ingest Document",
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
        metrics = _extract_metrics_from_state(output_state) or {}
        if started_at:
            elapsed = round(time.perf_counter() - started_at, 2)
            metrics["generation_seconds"] = metrics.get("generation_seconds") or elapsed
            metrics["worked_for"] = f"{elapsed}s"
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
            in_thinking_mode = False
            thinking_start_time: float | None = None
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

                # Parse reasoning / <think> blocks (DeepSeek-R1 / QwQ)
                if event["event"] == "on_chat_model_stream":
                    chunk = event.get("data", {}).get("chunk")
                    # Check for explicit reasoning_content in additional_kwargs (e.g. DeepSeek API)
                    if hasattr(
                        chunk, "additional_kwargs"
                    ) and chunk.additional_kwargs.get("reasoning_content"):
                        if thinking_start_time is None:
                            thinking_start_time = time.perf_counter()
                        reasoning_text = chunk.additional_kwargs["reasoning_content"]
                        yield {
                            "event": "on_reasoning_stream",
                            "data": {"text": reasoning_text},
                        }
                    elif hasattr(chunk, "content") and isinstance(chunk.content, str):
                        txt = chunk.content
                        if thinking_start_time is not None and not in_thinking_mode:
                            # Concluded explicit reasoning_content stream
                            t_dur_ms = round(
                                (time.perf_counter() - thinking_start_time) * 1000
                            )
                            thinking_start_time = None
                            yield {
                                "event": "on_reasoning_end",
                                "data": {
                                    "duration_ms": t_dur_ms,
                                    "seconds": round(t_dur_ms / 1000, 1),
                                },
                            }

                        if "<think>" in txt:
                            in_thinking_mode = True
                            thinking_start_time = time.perf_counter()
                            parts = txt.split("<think>", 1)
                            if parts[0]:
                                yield event
                            if "</think>" in parts[1]:
                                think_body, after_think = parts[1].split("</think>", 1)
                                t_dur_ms = round(
                                    (time.perf_counter() - thinking_start_time) * 1000
                                )
                                yield {
                                    "event": "on_reasoning_stream",
                                    "data": {"text": think_body},
                                }
                                yield {
                                    "event": "on_reasoning_end",
                                    "data": {
                                        "duration_ms": t_dur_ms,
                                        "seconds": round(t_dur_ms / 1000, 1),
                                    },
                                }
                                in_thinking_mode = False
                                thinking_start_time = None
                                if after_think:
                                    chunk.content = after_think
                                    yield event
                                continue
                            else:
                                if parts[1]:
                                    yield {
                                        "event": "on_reasoning_stream",
                                        "data": {"text": parts[1]},
                                    }
                                continue
                        elif in_thinking_mode:
                            if "</think>" in txt:
                                think_body, after_think = txt.split("</think>", 1)
                                t_dur_ms = (
                                    round(
                                        (time.perf_counter() - thinking_start_time)
                                        * 1000
                                    )
                                    if thinking_start_time
                                    else 0
                                )
                                if think_body:
                                    yield {
                                        "event": "on_reasoning_stream",
                                        "data": {"text": think_body},
                                    }
                                yield {
                                    "event": "on_reasoning_end",
                                    "data": {
                                        "duration_ms": t_dur_ms,
                                        "seconds": round(t_dur_ms / 1000, 1),
                                    },
                                }
                                in_thinking_mode = False
                                thinking_start_time = None
                                if after_think:
                                    chunk.content = after_think
                                    yield event
                            else:
                                yield {
                                    "event": "on_reasoning_stream",
                                    "data": {"text": txt},
                                }
                            continue

                if event["event"] == "on_chat_model_end":
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

                if (
                    event["event"] == "on_chain_end"
                    and event.get("name") == "LangGraph"
                ):
                    for e in _handle_chain_end_langgraph(event, started_at):
                        yield e

                yield event

        if is_temporary:
            app = workflow.compile()
            async for evt in _process_stream(
                app.astream_events(initial_state, config=config, version="v2")
            ):
                yield evt
        else:
            async with AsyncPostgresSaver.from_conn_string(
                config_obj.postgres_url
            ) as memory:
                await memory.setup()
                app = workflow.compile(checkpointer=memory)
                async for evt in _process_stream(
                    app.astream_events(initial_state, config=config, version="v2")
                ):
                    yield evt
    finally:
        _request_api_key.reset(token_api)
        _request_base_url.reset(token_base_url)
        _request_model.reset(token_model)
