from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

from backend.mcp_server.llm_loop import answer_question, stream_answer_question


@pytest.fixture
def mock_config():
    with patch("backend.mcp_server.llm_loop.get_config") as mock_get_config:
        mock_conf = MagicMock()
        mock_conf.default_search_limit = 5
        mock_conf.default_max_hops = 2
        mock_conf.llm_api_key = "test_key"
        mock_conf.llm_model_name = "test_model"
        mock_conf.llm_base_url = "http://test"
        mock_conf.redis_url = "redis://localhost:6379/0"
        mock_conf.postgres_url = (
            "postgresql://postgres:postgres@localhost:5432/postgres"
        )
        mock_conf.searxng_url = "http://searxng"
        mock_get_config.return_value = mock_conf
        yield mock_conf


# Removed mock_app fixture


@pytest.fixture
def mock_postgres_saver():
    with patch("backend.mcp_server.llm_loop.AsyncPostgresSaver") as mock_ps:
        mock_saver_instance = AsyncMock()
        mock_saver_instance.setup = AsyncMock()

        # Mock the async context manager returned by from_conn_string
        mock_cm = AsyncMock()
        mock_cm.__aenter__.return_value = mock_saver_instance

        mock_ps.from_conn_string.return_value = mock_cm
        yield mock_ps


@pytest.mark.asyncio
async def test_answer_question_basic(mock_config, mock_postgres_saver):
    # Setup mock workflow graph
    mock_workflow = AsyncMock()
    mock_workflow.ainvoke.return_value = {
        "messages": [HumanMessage(content="Hello"), AIMessage(content="Hi there!")]
    }

    with patch("backend.mcp_server.llm_loop._get_workflow") as mock_gw:
        mock_gw.return_value.compile.return_value = mock_workflow

        result = await answer_question(
            question="Hello", tenant_id="default", thread_id="thread_1"
        )

        assert result == "Hi there!"


@pytest.mark.asyncio
async def test_stream_answer_question_basic(mock_config, mock_postgres_saver):
    # Mocking the async generator for astream_events
    async def mock_astream_events(*args, **kwargs):
        yield {
            "event": "on_chat_model_stream",
            "data": {"chunk": AIMessage(content="Chunk 1")},
        }
        yield {
            "event": "on_chat_model_stream",
            "data": {"chunk": AIMessage(content="Chunk 2")},
        }

    mock_workflow = AsyncMock()
    mock_workflow.astream_events = mock_astream_events

    with patch("backend.mcp_server.llm_loop._get_workflow") as mock_gw:
        mock_gw.return_value.compile.return_value = mock_workflow

        chunks = []
        async for chunk in stream_answer_question(
            question="Stream this", tenant_id="default", thread_id="thread_2"
        ):
            chunks.append(chunk)

        chat_chunks = [c for c in chunks if c.get("event") == "on_chat_model_stream"]
        assert len(chat_chunks) >= 2
        assert chat_chunks[0]["data"]["chunk"].content == "Chunk 1"
        assert chat_chunks[1]["data"]["chunk"].content == "Chunk 2"
        assert any(c.get("event") == "on_step_start" for c in chunks)


from backend.mcp_server.orchestrator import route_evaluation, should_continue


def test_route_evaluation():
    assert route_evaluation({"context_relevance": "yes"}) == "agent"
    assert route_evaluation({"context_relevance": "no"}) == "web_search"
    assert route_evaluation({}) == "agent"  # default is yes


def test_should_continue():
    from langchain_core.messages import AIMessage

    # Test tool calls
    msg_with_tool = AIMessage(
        content="", tool_calls=[{"name": "test_tool", "args": {}, "id": "1"}]
    )
    assert should_continue({"messages": [msg_with_tool]}) == "tools"

    # Test no tool calls
    msg_without_tool = AIMessage(content="Hello")
    assert should_continue({"messages": [msg_without_tool]}) == "__end__"


@pytest.mark.asyncio
async def test_evaluate_context(mock_config):
    from langchain_core.messages import HumanMessage

    from backend.mcp_server.orchestrator import GradeDocuments, evaluate_context

    # Test empty context
    res = await evaluate_context(
        {"messages": [HumanMessage(content="Hello")], "retrieved_context": ""}
    )
    assert res["context_relevance"] == "no"

    # Test valid context, mock structured llm
    mock_llm = AsyncMock()
    mock_llm.ainvoke.return_value = GradeDocuments(binary_score="yes")

    with patch("backend.mcp_server.orchestrator._create_chat_llm") as mock_create_chat:
        mock_create_chat.return_value.with_structured_output.return_value.with_config.return_value = mock_llm
        res = await evaluate_context(
            {
                "messages": [HumanMessage(content="Hello")],
                "retrieved_context": "Some useful text",
            }
        )
        assert res["context_relevance"] == "yes"


def test_grader_construction():
    from unittest.mock import patch

    from backend.mcp_server.orchestrator import GradeDocuments, _create_chat_llm

    # Test that constructing the grader does not raise an error
    with patch("backend.mcp_server.orchestrator.get_config") as mock_get_config:
        mock_get_config.return_value.is_enterprise = False
        mock_get_config.return_value.get_llm_client_args.return_value = {}
        llm = _create_chat_llm("gpt-4o", "fake-key")
        structured_llm_grader = llm.with_structured_output(
            GradeDocuments, method="function_calling"
        ).with_config(tags=["crag_evaluator"])
        assert structured_llm_grader is not None


@pytest.mark.asyncio
async def test_web_search_fallback(mock_config):
    import io
    import json

    from langchain_core.messages import HumanMessage

    from backend.mcp_server.orchestrator import web_search_fallback

    mock_response = io.BytesIO(
        json.dumps(
            {"results": [{"url": "http://example.com", "content": "Example web text"}]}
        ).encode("utf-8")
    )

    with patch("urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value.__enter__.return_value = mock_response

        res = await web_search_fallback(
            {"messages": [HumanMessage(content="Search query")]}
        )
        assert "retrieved_context" in res


@pytest.mark.asyncio
async def test_execute_tools():
    from langchain_core.messages import AIMessage

    from backend.mcp_server.orchestrator import execute_tools

    # Mock tool call
    msg_with_tool = AIMessage(
        content="", tool_calls=[{"name": "test_tool", "args": {}, "id": "1"}]
    )

    with patch("backend.mcp_server.tool_dispatch._execute_single_tool") as mock_exec:
        mock_exec.return_value = ([], [])  # v_hits, g_hits

        state = {
            "messages": [msg_with_tool],
            "tenant_id": "test_tenant",
        }

        res = await execute_tools(state)
        assert len(res["messages"]) == 1
        assert res["retrieved_context"] == "No results found."


@pytest.mark.asyncio
async def test_get_tools(mock_config):
    from backend.mcp_server.tool_dispatch import get_tools

    tools = await get_tools({"file_search_enabled": True})
    assert len(tools) > 0
    assert tools[0]["function"]["name"] == "search_vectors"


@pytest.mark.asyncio
async def test_call_model(mock_config):
    from backend.mcp_server.orchestrator import call_model

    msg = HumanMessage(content="Hello")

    mock_llm = AsyncMock()
    mock_llm.ainvoke.return_value = AIMessage(content="Hi there!", additional_kwargs={})

    with patch("backend.mcp_server.orchestrator._create_chat_llm") as mock_create:
        mock_create.return_value = mock_llm
        mock_llm.bind_tools = MagicMock(return_value=mock_llm)

        state = {
            "messages": [msg],
            "calculate_grounding": False,
        }

        res = await call_model(state)
        assert len(res["messages"]) == 1
        assert res["messages"][0].content == "Hi there!"


@pytest.mark.asyncio
async def test_call_model_does_not_replay_reasoning_content(mock_config):
    from backend.mcp_server.orchestrator import call_model

    mock_llm = AsyncMock()
    mock_llm.ainvoke.return_value = AIMessage(content="Hi there!", additional_kwargs={})

    with patch("backend.mcp_server.orchestrator._create_chat_llm") as mock_create:
        mock_create.return_value = mock_llm
        mock_llm.bind_tools = MagicMock(return_value=mock_llm)

        state = {
            "messages": [
                HumanMessage(content="Hello"),
                AIMessage(
                    content="Previous answer",
                    additional_kwargs={
                        "reasoning_content": "private provider trace",
                        "model_name": "test-model",
                    },
                ),
            ],
            "calculate_grounding": False,
        }

        await call_model(state)

        sent_messages = mock_llm.ainvoke.call_args.args[0]
        assert all(
            "reasoning_content" not in message.additional_kwargs
            for message in sent_messages
        )
        assert state["messages"][1].additional_kwargs["reasoning_content"]


def test_execute_single_tool(mock_config):
    from backend.mcp_server.tool_dispatch import _execute_single_tool

    # Test time tool
    v_hits, g_hits = _execute_single_tool("get_current_time", {}, "test_tenant")
    assert len(v_hits) == 1
    assert "current_utc_time" in v_hits[0].payload

    # Test unknown tool
    v_hits, g_hits = _execute_single_tool("unknown_tool", {}, "test_tenant")
    assert len(v_hits) == 0
    assert len(g_hits) == 0

    # Test fetch_url tool mock
    with patch("requests.get") as mock_get:
        mock_get.return_value.text = "Hello World"
        mock_get.return_value.raise_for_status = MagicMock()
        v_hits, g_hits = _execute_single_tool(
            "fetch_url", {"url": "http://test.com"}, "test_tenant"
        )
        assert len(v_hits) == 1
        assert v_hits[0].payload["content"] == "Hello World"

    # Test run_python_code mock
    with patch("requests.post") as mock_post:
        mock_post.return_value.json.return_value = {
            "stdout": "42",
            "stderr": "",
            "exit_code": 0,
        }
        mock_post.return_value.raise_for_status = MagicMock()
        v_hits, g_hits = _execute_single_tool(
            "run_python_code", {"code": "print(42)"}, "test_tenant"
        )
        assert len(v_hits) == 1
        assert v_hits[0].payload["stdout"] == "42"

        # Test error
        mock_post.side_effect = Exception("error")
        with patch(
            "backend.mcp_server.tools.run_code.execute_python_code",
            side_effect=Exception("sandbox error"),
        ):
            v_hits, g_hits = _execute_single_tool(
                "run_python_code", {"code": "print(42)"}, "test_tenant"
            )
            assert len(v_hits) == 1
            assert "error" in v_hits[0].payload

    # Test search_vectors mock
    with patch("backend.mcp_server.tool_dispatch.search_vectors") as mock_sv:
        mock_sv.return_value = [MagicMock()]
        v_hits, g_hits = _execute_single_tool(
            "search_vectors",
            {"query_text": "test", "limit": 5},
            "test_tenant",
            tool_settings={"file_search_enabled": True},
        )
        assert len(v_hits) == 1

    # Test query_graph mock
    with patch("backend.mcp_server.tool_dispatch.query_graph") as mock_qg:
        mock_qg.return_value = [MagicMock()]
        v_hits, g_hits = _execute_single_tool(
            "query_graph",
            {"entity_name": "test", "max_hops": 2},
            "test_tenant",
            tool_settings={"file_search_enabled": True},
        )
        assert len(g_hits) == 1

    # Test web_search mock
    with patch("backend.mcp_server.tools.web_search.mcp_web_search") as mock_ws:
        mock_ws.return_value = [
            {"content": "result", "snippet": "snippet", "title": "title", "url": "url"}
        ]
        v_hits, g_hits = _execute_single_tool(
            "web_search",
            {"query": "test"},
            "test_tenant",
            tool_settings={"web_search": {"enabled": True}},
        )
        assert len(v_hits) == 1
        assert v_hits[0].payload["text"] == "result"

    # Test agentic_debate mock
    with patch(
        "backend.mcp_server.orchestrator_multi_agent.mcp_agentic_debate"
    ) as mock_ad:

        async def _mock_debate(*args, **kwargs):
            return {
                "results": [
                    {
                        "id": "res_1",
                        "text": "Debate verified text",
                        "sources": ["Multi-Agent"],
                    }
                ]
            }

        mock_ad.side_effect = _mock_debate
        v_hits, g_hits = _execute_single_tool(
            "agentic_debate",
            {"query": "test query"},
            "test_tenant",
            tool_settings={"web_search": {"enabled": True}},
        )
        assert len(v_hits) == 1
        assert v_hits[0].payload["text"] == "Debate verified text"
        assert v_hits[0].payload["title"] == "Agentic Debate Verified Answer"


def test_handle_stream_events():
    from langchain_core.messages import AIMessage

    from backend.mcp_server.llm_loop import (
        _handle_chain_end_langgraph,
        _handle_chain_end_tools,
        _handle_chat_model_end,
    )

    # Test _handle_chat_model_end
    msg = AIMessage(
        content="",
        tool_calls=[{"name": "test_tool", "args": {"arg": "val"}, "id": "1"}],
    )
    events = _handle_chat_model_end({"data": {"output": msg}})
    assert len(events) == 1
    assert events[0]["event"] == "on_tool_start"

    # Test _handle_chain_end_tools
    msg = ToolMessage(content="test output", name="test_tool", tool_call_id="1")
    msg.artifact = [{"some": "data"}]
    events = _handle_chain_end_tools({"data": {"output": {"messages": [msg]}}})
    assert len(events) == 1
    assert events[0]["event"] == "on_tool_end"

    # Test _handle_chain_end_langgraph
    msg_with_metrics = AIMessage(content="", additional_kwargs={"metrics": {"time": 1}})
    events = _handle_chain_end_langgraph(
        {"data": {"output": {"messages": [msg_with_metrics]}}}
    )
    assert len(events) == 1
    assert events[0]["event"] == "metadata"


def test_helpers():
    from backend.mcp_server.formatter import _cosine_similarity
    from backend.mcp_server.tool_dispatch import _build_context_string

    # Test _cosine_similarity
    assert _cosine_similarity([1, 0], [1, 0]) == 1.0
    assert _cosine_similarity([1, 0], [0, 1]) == 0.0
    assert _cosine_similarity([0, 0], [1, 1]) == 0.0

    # Test _build_context_string
    class DummyHit:
        def __init__(self, sources, payload):
            self.sources = sources
            self.payload = payload

    res = _build_context_string(
        [
            DummyHit(["source1"], {"text": "hello"}),
            DummyHit(["source2"], {"content": "world"}),
        ]
    )
    assert "source1" in res
    assert "hello" in res
    assert "source2" in res
    assert "world" in res


def test_simple_helpers():
    import os
    from unittest.mock import patch

    from langchain_core.messages import HumanMessage, SystemMessage

    from backend.mcp_server.formatter import _prepend_system_messages
    from backend.mcp_server.llm_loop import _apply_observability_settings

    # Test _apply_observability_settings
    with patch.dict(os.environ, {}):
        _apply_observability_settings(
            {
                "observability": {
                    "langsmith_enabled": True,
                    "langsmith_api_key": "test_key",
                }
            }
        )
        assert os.environ.get("LANGCHAIN_PROJECT") == "Veraxi"
        assert os.environ.get("LANGCHAIN_TRACING_V2") == "true"

    # Test _prepend_system_messages
    msgs = [HumanMessage(content="test")]
    new_msgs = _prepend_system_messages(msgs, [SystemMessage(content="sys")])
    assert len(new_msgs) == 3
    assert new_msgs[1].content == "sys"
    assert new_msgs[2].content == "test"


@pytest.mark.asyncio
async def test_code_mode_auto_enables_repo_tools_and_defaults_repo(mock_config):
    from unittest.mock import AsyncMock, patch

    from backend.mcp_server.tool_dispatch import execute_tools_internal, get_tools

    tools = await get_tools(
        {"workspace_mode": "code", "repo_key": "kcoaguila-dev/veraxi", "file_search_enabled": False},
        tenant_id="t1",
    )
    names = {t["function"]["name"] for t in tools}
    assert {"code_read_file", "code_list_files", "code_symbol", "code_impact", "code_overview"} <= names

    with patch(
        "backend.mcp_server.tools.code_tools.code_read_file",
        new=AsyncMock(
            return_value={
                "path": "README.md",
                "repo_key": "kcoaguila-dev/veraxi",
                "start_line": 1,
                "end_line": 1,
                "total_lines": 1,
                "url": "file://README.md#L1-L1",
                "content": "# Veraxi",
                "truncated": False,
            }
        ),
    ) as mock_read:
        ctx, _ = await execute_tools_internal(
            [{"id": "tc1", "name": "code_read_file", "args": {"path": "README.md"}}],
            "t1",
            {"workspace_mode": "code", "repo_key": "kcoaguila-dev/veraxi"},
        )
        assert mock_read.await_args.kwargs["repo"] == "kcoaguila-dev/veraxi"
        assert "# Veraxi" in ctx
        assert "file://README.md#L1-L1" in ctx


@pytest.mark.asyncio
async def test_call_model_injects_workspace_context_and_allows_multistep_in_code_mode(mock_config):
    from unittest.mock import AsyncMock, MagicMock, patch

    from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

    from backend.mcp_server.orchestrator import MAX_CODE_TOOL_ROUNDS, call_model

    captured_messages = []

    class FakeBoundLlm:
        async def ainvoke(self, msgs):
            captured_messages.append(msgs)
            return AIMessage(content="Done reading README.")

    fake_llm = MagicMock()
    fake_llm.bind_tools.return_value = FakeBoundLlm()
    fake_llm.ainvoke = AsyncMock(return_value=AIMessage(content="No tools."))

    with (
        patch("backend.mcp_server.orchestrator._create_chat_llm", return_value=fake_llm),
        patch(
            "backend.services.repo_context.build_workspace_context_prompt",
            new=AsyncMock(return_value="<workspace_context>\nActive Repository: kcoaguila-dev/veraxi\n</workspace_context>"),
        ),
        patch("backend.mcp_server.orchestrator.get_tools", new=AsyncMock(return_value=[{"type": "function", "function": {"name": "code_read_file", "parameters": {"type": "object", "properties": {}}}}])),
    ):
        # After 1 tool round in Code Mode -> tools are STILL bound!
        state_after_one_tool = {
            "messages": [
                HumanMessage(content="read the readme"),
                AIMessage(content="", tool_calls=[{"id": "c1", "name": "code_list_files", "args": {}}]),
                ToolMessage(content="README.md", tool_call_id="c1"),
            ],
            "tenant_id": "t1",
            "context_relevance": "",
            "retrieved_context": "",
            "query_embedding": None,
            "calculate_grounding": False,
            "tool_settings": {"workspace_mode": "code", "repo_key": "kcoaguila-dev/veraxi"},
        }
        await call_model(state_after_one_tool)
        assert fake_llm.bind_tools.called
        assert any(
            "Active Repository: kcoaguila-dev/veraxi" in str(m.content)
            for m in captured_messages[0]
        )

        # At MAX_CODE_TOOL_ROUNDS -> tools are NOT bound anymore (hard cap)
        fake_llm.bind_tools.reset_mock()
        many_msgs = [HumanMessage(content="loop")]
        for i in range(MAX_CODE_TOOL_ROUNDS):
            many_msgs.append(
                AIMessage(content="", tool_calls=[{"id": f"c{i}", "name": "code_list_files", "args": {}}])
            )
            many_msgs.append(ToolMessage(content="README.md", tool_call_id=f"c{i}"))
        state_at_cap = {
            **state_after_one_tool,
            "messages": many_msgs,
        }
        await call_model(state_at_cap)
        assert not fake_llm.bind_tools.called
        assert fake_llm.ainvoke.called


@pytest.mark.asyncio
async def test_evaluate_context_skips_web_fallback_for_empty_code_tool(mock_config):
    from langchain_core.messages import AIMessage, HumanMessage

    from backend.mcp_server.orchestrator import evaluate_context

    state = {
        "messages": [
            HumanMessage(content="do you see the readme?"),
            AIMessage(content="", tool_calls=[{"id": "c1", "name": "code_read_file", "args": {"path": "README.md"}}]),
        ],
        "tenant_id": "t1",
        "retrieved_context": "No results found.",
    }
    res = await evaluate_context(state)
    assert res["context_relevance"] == "yes"


@pytest.mark.asyncio
async def test_stream_answer_question_emits_agent_metrics_before_rate_limit(mock_config):
    from unittest.mock import MagicMock, patch

    from langchain_core.messages import AIMessage

    from backend.mcp_server.llm_loop import stream_answer_question

    agent_msg = AIMessage(
        content="",
        additional_kwargs={
            "metrics": {
                "prompt_tokens": 4300,
                "completion_tokens": 150,
                "total_tokens": 4450,
            }
        },
    )

    async def fake_astream_events(*args, **kwargs):
        yield {
            "event": "on_chain_end",
            "name": "agent",
            "data": {"output": {"messages": [agent_msg]}},
        }
        raise RuntimeError("RateLimitError: tokens per minute (TPM) limit")

    fake_app = MagicMock()
    fake_app.astream_events = fake_astream_events
    fake_workflow = MagicMock()
    fake_workflow.compile.return_value = fake_app

    emitted = []
    with (
        patch("backend.mcp_server.llm_loop._get_workflow", return_value=fake_workflow),
        pytest.raises(RuntimeError, match="TPM"),
    ):
        async for ev in stream_answer_question(
            "hi", tenant_id="t1", thread_id="th1", is_temporary=True
        ):
            emitted.append(ev)

    metadata_events = [e for e in emitted if e.get("event") == "metadata"]
    assert len(metadata_events) == 1
    metrics = metadata_events[0]["data"]["metrics"]
    assert metrics["prompt_tokens"] == 4300
    assert metrics["completion_tokens"] == 150
    assert metrics["total_tokens"] == 4450
