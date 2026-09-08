import logging
import os
from collections.abc import AsyncGenerator

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
from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

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




def _handle_chat_model_end(event: dict) -> list[dict]:
    events = []
    msg = event.get("data", {}).get("output")
    if hasattr(msg, "tool_calls") and msg.tool_calls:
        for tc in msg.tool_calls:
            events.append(
                {
                    "event": "on_tool_start",
                    "name": tc.get("name", "tool"),
                    "run_id": tc.get("id", ""),
                    "data": {"input": tc.get("args", {})},
                }
            )
    return events


def _handle_chain_end_tools(event: dict) -> list[dict]:
    events = []
    output = event.get("data", {}).get("output", {})
    if isinstance(output, dict) and "messages" in output:
        for m in output["messages"]:
            if hasattr(m, "tool_call_id") and m.tool_call_id:
                events.append(
                    {
                        "event": "on_tool_end",
                        "name": m.name or "tool",
                        "run_id": m.tool_call_id,
                        "data": {
                            "output": m.content,
                            "artifact": getattr(m, "artifact", None),
                        },
                    }
                )
    return events


def _handle_chain_end_langgraph(event: dict) -> list[dict]:
    events = []
    output_state = (
        event.get("data", {}).get("output") or event.get("data", {}).get("chunk") or {}
    )
    if isinstance(output_state, dict):
        metrics = _extract_metrics_from_state(output_state)
        if metrics:
            events.append({"event": "metadata", "data": {"metrics": metrics}})
    return events


def _handle_chat_model_end(event: dict) -> list[dict]:
    events = []
    msg = event.get("data", {}).get("output")
    if hasattr(msg, "tool_calls") and msg.tool_calls:
        for tc in msg.tool_calls:
            events.append(
                {
                    "event": "on_tool_start",
                    "name": tc.get("name", "tool"),
                    "run_id": tc.get("id", ""),
                    "data": {"input": tc.get("args", {})},
                }
            )
    return events


def _handle_chain_end_tools(event: dict) -> list[dict]:
    events = []
    output = event.get("data", {}).get("output", {})
    if isinstance(output, dict) and "messages" in output:
        for m in output["messages"]:
            if hasattr(m, "tool_call_id") and m.tool_call_id:
                events.append(
                    {
                        "event": "on_tool_end",
                        "name": m.name or "tool",
                        "run_id": m.tool_call_id,
                        "data": {
                            "output": m.content,
                            "artifact": getattr(m, "artifact", None),
                        },
                    }
                )
    return events


def _handle_chain_end_langgraph(event: dict) -> list[dict]:
    events = []
    output_state = (
        event.get("data", {}).get("output") or event.get("data", {}).get("chunk") or {}
    )
    if isinstance(output_state, dict):
        metrics = _extract_metrics_from_state(output_state)
        if metrics:
            events.append({"event": "metadata", "data": {"metrics": metrics}})
    return events


def _handle_chain_end_tools(event: dict) -> list[dict]:
    events = []
    output = event.get("data", {}).get("output", {})
    if isinstance(output, dict) and "messages" in output:
        for m in output["messages"]:
            if hasattr(m, "tool_call_id") and m.tool_call_id:
                events.append(
                    {
                        "event": "on_tool_end",
                        "name": m.name or "tool",
                        "run_id": m.tool_call_id,
                        "data": {
                            "output": m.content,
                            "artifact": getattr(m, "artifact", None),
                        },
                    }
                )
    return events


def _handle_chain_end_langgraph(event: dict) -> list[dict]:
    events = []
    output_state = (
        event.get("data", {}).get("output") or event.get("data", {}).get("chunk") or {}
    )
    if isinstance(output_state, dict):
        metrics = _extract_metrics_from_state(output_state)
        if metrics:
            events.append({"event": "metadata", "data": {"metrics": metrics}})
    return events


def _handle_chain_end_langgraph(event: dict) -> list[dict]:
    events = []
    output_state = (
        event.get("data", {}).get("output") or event.get("data", {}).get("chunk") or {}
    )
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

        logger.info(
            f"Starting async streaming LangGraph run for thread_id={thread_id} (temporary={is_temporary})"
        )
        workflow = _get_workflow()

        async def _process_stream(stream):
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

                if event["event"] == "on_chat_model_end":
                    for e in _handle_chat_model_end(event):
                        yield e

                if event["event"] == "on_chain_end" and event.get("name") in [
                    "execute_tools",
                    "tools",
                ]:
                    for e in _handle_chain_end_tools(event):
                        yield e

                if (
                    event["event"] == "on_chain_end"
                    and event.get("name") == "LangGraph"
                ):
                    for e in _handle_chain_end_langgraph(event):
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



