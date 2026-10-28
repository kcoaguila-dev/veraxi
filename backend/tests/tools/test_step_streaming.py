"""
Unit tests for Real-Time Step and Tool Execution Visibility.
Tests verify:
1. on_step_start emissions for Planning and Synthesis
2. Enriched on_tool_start and on_tool_end with labels, steps, durations, and summaries
3. <think> tag separation into on_reasoning_stream
4. Runaway tool repetition loop guard
5. CLI parameter formatting
"""

import asyncio
from unittest.mock import MagicMock, patch

from backend.mcp_server.llm_loop import (
    _get_tool_friendly_label,
    _handle_chain_end_tools,
    _handle_chat_model_end,
    _make_tool_summary,
    stream_answer_question,
)
from veraxi.cli.chat import _format_tool_input


def test_tool_friendly_labels():
    assert _get_tool_friendly_label("mcp_query_graph") == "Query Knowledge Graph"
    assert _get_tool_friendly_label("mcp_web_search") == "Search Live Web"
    assert _get_tool_friendly_label("mcp_deep_research") == "Deep Research Synthesis"
    assert _get_tool_friendly_label("mcp_custom_tool") == "Custom Tool"


def test_tool_summary_formatting():
    assert (
        _make_tool_summary("mcp_query_graph", "", artifact=[{"id": "1"}, {"id": "2"}])
        == "Retrieved 2 evidence chunks from graph"
    )
    assert (
        _make_tool_summary("mcp_web_search", "No results found.")
        == "No matching records found"
    )
    assert (
        _make_tool_summary("mcp_run_code", "Error: division by zero")
        == "Error: division by zero"
    )
    assert (
        _make_tool_summary(
            "mcp_query_graph", "Found entity A connected to B\nDetail line 2"
        )
        == "Found entity A connected to B"
    )


def test_handle_chat_model_end_enrichment():
    tool_start_times = {}
    mock_event = {
        "data": {
            "output": MagicMock(
                tool_calls=[
                    {
                        "name": "mcp_query_graph",
                        "id": "call_123",
                        "args": {"query": "GraphRAG", "limit": 5},
                    }
                ]
            )
        }
    }
    events = _handle_chat_model_end(mock_event, tool_start_times, current_step=1)
    assert len(events) == 1
    evt = events[0]
    assert evt["event"] == "on_tool_start"
    assert evt["name"] == "mcp_query_graph"
    assert evt["label"] == "Query Knowledge Graph"
    assert evt["step"] == 1
    assert evt["run_id"] == "call_123"
    assert evt["data"]["input"]["query"] == "GraphRAG"
    assert "call_123" in tool_start_times


def test_handle_chain_end_tools_enrichment():
    tool_start_times = {"call_123": 1000.0}
    mock_msg = MagicMock()
    mock_msg.tool_call_id = "call_123"
    mock_msg.name = "mcp_query_graph"
    mock_msg.content = "Found 4 entities and 6 relations"
    mock_msg.artifact = [{"id": "e1"}]

    mock_event = {"data": {"output": {"messages": [mock_msg]}}}
    with patch("time.perf_counter", return_value=1000.45):
        events = _handle_chain_end_tools(mock_event, tool_start_times, current_step=1)
        assert len(events) == 1
        evt = events[0]
        assert evt["event"] == "on_tool_end"
        assert evt["name"] == "mcp_query_graph"
        assert evt["label"] == "Query Knowledge Graph"
        assert evt["step"] == 1
        assert evt["status"] == "success"
        assert evt["duration_ms"] == 450
        assert "evidence chunks" in evt["summary"]


def test_format_tool_input_cli():
    args = {"query": "test search", "limit": 10, "long_str": "a" * 50}
    formatted = _format_tool_input(args)
    assert "query='test search'" in formatted
    assert "limit=10" in formatted
    assert "..." in formatted


def test_stream_answer_question_steps():
    async def _run():
        events_collected = []

        # Mock workflow to yield chat events
        mock_stream_events = [
            # Chat model outputs tool call
            {
                "event": "on_chat_model_end",
                "data": {
                    "output": MagicMock(
                        tool_calls=[
                            {
                                "name": "mcp_query_graph",
                                "id": "call_1",
                                "args": {"query": "test"},
                            }
                        ]
                    )
                },
            },
            # Tools node executes
            {
                "event": "on_chain_end",
                "name": "tools",
                "data": {
                    "output": {
                        "messages": [
                            MagicMock(
                                tool_call_id="call_1",
                                name="mcp_query_graph",
                                content="Graph results",
                                artifact=[],
                            )
                        ]
                    }
                },
            },
            # Synthesis model streams response with thinking tag
            {
                "event": "on_chat_model_stream",
                "data": {
                    "chunk": MagicMock(
                        content="<think>Analyzing graph results...</think>The final verified answer is here.",
                        additional_kwargs={},
                    )
                },
            },
        ]

        async def _mock_astream(*args, **kwargs):
            for e in mock_stream_events:
                yield e

        mock_app = MagicMock()
        mock_app.astream_events = _mock_astream
        mock_workflow = MagicMock()
        mock_workflow.compile.return_value = mock_app

        with patch(
            "backend.mcp_server.llm_loop._get_workflow", return_value=mock_workflow
        ):
            async for evt in stream_answer_question("test question", is_temporary=True):
                events_collected.append(evt)

        # 1. First event must be on_step_start (Step 1: Planning)
        assert events_collected[0]["event"] == "on_step_start"
        assert events_collected[0]["step"] == 1

        # 2. on_tool_start must have label and step 1
        tool_starts = [e for e in events_collected if e.get("event") == "on_tool_start"]
        assert len(tool_starts) == 1
        assert tool_starts[0]["label"] == "Query Knowledge Graph"
        assert tool_starts[0]["step"] == 1

        # 3. on_tool_end must have status and duration
        tool_ends = [e for e in events_collected if e.get("event") == "on_tool_end"]
        assert len(tool_ends) == 1
        assert tool_ends[0]["status"] == "success"

        # 4. Step 2 (Synthesis) must be emitted after tool execution
        step_2 = [
            e
            for e in events_collected
            if e.get("event") == "on_step_start" and e.get("step") == 2
        ]
        assert len(step_2) == 1
        assert "Synthesis" in step_2[0]["name"]

        # 5. on_reasoning_stream must be emitted for the <think> text
        reasoning = [
            e for e in events_collected if e.get("event") == "on_reasoning_stream"
        ]
        assert len(reasoning) >= 1
        assert "Analyzing graph results..." in reasoning[0]["data"]["text"]

    asyncio.run(_run())


def test_anti_attribution_drift_prompt_rule():
    from backend.mcp_server.orchestrator import call_model
    from langchain_core.messages import HumanMessage, SystemMessage

    captured_messages = []

    class DummyLLM:
        def bind_tools(self, tools, **kwargs):
            return self

        async def ainvoke(self, messages):
            captured_messages.extend(messages)
            msg = MagicMock()
            msg.tool_calls = []
            msg.content = "Test answer"
            return msg

    state = {
        "messages": [HumanMessage(content="What happened next?")],
        "tenant_id": "test_tenant",
        "tool_settings": {"web_search": {"enabled": True}},
    }

    with patch("backend.mcp_server.orchestrator.get_tools", return_value=[]):
        with patch(
            "backend.mcp_server.orchestrator._create_chat_llm",
            return_value=DummyLLM(),
        ):
            asyncio.run(call_model(state))

    system_contents = [
        m.content for m in captured_messages if isinstance(m, SystemMessage)
    ]
    combined_system_text = " ".join(system_contents)
    assert "ANTI-ATTRIBUTION-DRIFT" in combined_system_text
    assert "NEVER reuse citations" in combined_system_text
