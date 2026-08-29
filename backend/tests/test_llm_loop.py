import pytest
from unittest.mock import patch, AsyncMock, MagicMock
from backend.mcp_server.llm_loop import answer_question, stream_answer_question
from langchain_core.messages import HumanMessage, AIMessage, ToolMessage

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
        mock_conf.postgres_url = "postgresql://postgres:postgres@localhost:5432/postgres"
        mock_conf.searxng_url = "http://searxng"
        mock_get_config.return_value = mock_conf
        yield mock_conf

@pytest.fixture
def mock_app():
    with patch("backend.mcp_server.llm_loop._app") as mock_a:
        yield mock_a

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
async def test_answer_question_basic(mock_config, mock_app, mock_postgres_saver):
    # Setup mock workflow graph
    mock_workflow = AsyncMock()
    mock_workflow.ainvoke.return_value = {
        "messages": [
            HumanMessage(content="Hello"),
            AIMessage(content="Hi there!")
        ]
    }
    
    with patch("backend.mcp_server.llm_loop._get_workflow") as mock_gw:
        mock_gw.return_value.compile.return_value = mock_workflow
        
        result = await answer_question(
            question="Hello",
            tenant_id="default",
            thread_id="thread_1"
        )
        
        assert result == "Hi there!"


@pytest.mark.asyncio
async def test_stream_answer_question_basic(mock_config, mock_app, mock_postgres_saver):
    # Mocking the async generator for astream_events
    async def mock_astream_events(*args, **kwargs):
        yield {
            "event": "on_chat_model_stream",
            "data": {
                "chunk": AIMessage(content="Chunk 1")
            }
        }
        yield {
            "event": "on_chat_model_stream",
            "data": {
                "chunk": AIMessage(content="Chunk 2")
            }
        }
    
    mock_workflow = AsyncMock()
    mock_workflow.astream_events = mock_astream_events
    
    with patch("backend.mcp_server.llm_loop._get_workflow") as mock_gw:
        mock_gw.return_value.compile.return_value = mock_workflow
        
        chunks = []
        async for chunk in stream_answer_question(
            question="Stream this",
            tenant_id="default",
            thread_id="thread_2"
        ):
            chunks.append(chunk)
            
        assert chunks[0]["event"] == "on_chat_model_stream"
        assert chunks[0]["data"]["chunk"].content == "Chunk 1"
        assert chunks[1]["data"]["chunk"].content == "Chunk 2"

from backend.mcp_server.llm_loop import route_evaluation, should_continue

def test_route_evaluation():
    assert route_evaluation({"context_relevance": "yes"}) == "agent"
    assert route_evaluation({"context_relevance": "no"}) == "web_search"
    assert route_evaluation({}) == "agent"  # default is yes

def test_should_continue():
    from langchain_core.messages import AIMessage
    
    # Test tool calls
    msg_with_tool = AIMessage(content="", tool_calls=[{"name": "test_tool", "args": {}, "id": "1"}])
    assert should_continue({"messages": [msg_with_tool]}) == "tools"
    
    # Test no tool calls
    msg_without_tool = AIMessage(content="Hello")
    assert should_continue({"messages": [msg_without_tool]}) == "__end__"

@pytest.mark.asyncio
async def test_evaluate_context(mock_config):
    from backend.mcp_server.llm_loop import evaluate_context, GradeDocuments
    from langchain_core.messages import HumanMessage
    
    # Test empty context
    res = await evaluate_context({"messages": [HumanMessage(content="Hello")], "retrieved_context": ""})
    assert res["context_relevance"] == "no"
    
    # Test valid context, mock structured llm
    mock_llm = AsyncMock()
    mock_llm.ainvoke.return_value = GradeDocuments(binary_score="yes")
    
    with patch("backend.mcp_server.llm_loop.ChatOpenAI") as mock_chat:
        mock_chat.return_value.with_structured_output.return_value = mock_llm
        res = await evaluate_context({"messages": [HumanMessage(content="Hello")], "retrieved_context": "Some useful text"})
        assert res["context_relevance"] == "yes"

@pytest.mark.asyncio
async def test_web_search_fallback(mock_config):
    from backend.mcp_server.llm_loop import web_search_fallback
    from langchain_core.messages import HumanMessage
    import json
    import io
    
    mock_response = io.BytesIO(json.dumps({
        "results": [
            {"url": "http://example.com", "content": "Example web text"}
        ]
    }).encode("utf-8"))
    
    with patch("urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value.__enter__.return_value = mock_response
        
        res = await web_search_fallback({"messages": [HumanMessage(content="Search query")]})
        assert "retrieved_context" in res
@pytest.mark.asyncio
async def test_execute_tools():
    from backend.mcp_server.llm_loop import execute_tools
    from langchain_core.messages import AIMessage
    
    # Mock tool call
    msg_with_tool = AIMessage(content="", tool_calls=[{"name": "test_tool", "args": {}, "id": "1"}])
    
    with patch("backend.mcp_server.llm_loop._execute_single_tool") as mock_exec:
        mock_exec.return_value = ([], []) # v_hits, g_hits
        
        state = {
            "messages": [msg_with_tool],
            "tenant_id": "test_tenant",
        }
        
        res = await execute_tools(state)
        assert len(res["messages"]) == 1
        assert res["retrieved_context"] == "No results found."

@pytest.mark.asyncio
async def test_get_tools(mock_config):
    from backend.mcp_server.llm_loop import get_tools
    tools = await get_tools({"file_search_enabled": True})
    assert len(tools) > 0
    assert tools[0]["function"]["name"] == "search_vectors"

@pytest.mark.asyncio
async def test_call_model(mock_config):
    from backend.mcp_server.llm_loop import call_model
    from langchain_core.messages import HumanMessage, AIMessage
    
    msg = HumanMessage(content="Hello")
    
    mock_llm = AsyncMock()
    mock_llm.ainvoke.return_value = AIMessage(content="Hi there!", additional_kwargs={})
    
    with patch("backend.mcp_server.llm_loop._create_chat_llm") as mock_create:
        mock_create.return_value.bind_tools.return_value = mock_llm
        
        state = {
            "messages": [msg],
            "calculate_grounding": False,
        }
        
        res = await call_model(state)
        assert len(res["messages"]) == 1
        assert res["messages"][0].content == "Hi there!"

def test_execute_single_tool(mock_config):
    from backend.mcp_server.llm_loop import _execute_single_tool
    
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
        v_hits, g_hits = _execute_single_tool("fetch_url", {"url": "http://test.com"}, "test_tenant")
        assert len(v_hits) == 1
        assert v_hits[0].payload["content"] == "Hello World"
        
    # Test run_python_code mock
    with patch("requests.post") as mock_post:
        mock_post.return_value.json.return_value = {"stdout": "42", "stderr": "", "exit_code": 0}
        mock_post.return_value.raise_for_status = MagicMock()
        v_hits, g_hits = _execute_single_tool("run_python_code", {"code": "print(42)"}, "test_tenant")
        assert len(v_hits) == 1
        assert v_hits[0].payload["stdout"] == "42"
        
        # Test error
        mock_post.side_effect = Exception("error")
        v_hits, g_hits = _execute_single_tool("run_python_code", {"code": "print(42)"}, "test_tenant")
        assert len(v_hits) == 1
        assert "error" in v_hits[0].payload

    # Test search_vectors mock
    with patch("backend.mcp_server.llm_loop.search_vectors") as mock_sv:
        mock_sv.return_value = [MagicMock()]
        v_hits, g_hits = _execute_single_tool("search_vectors", {"query_text": "test", "limit": 5}, "test_tenant", tool_settings={"file_search_enabled": True})
        assert len(v_hits) == 1
        
    # Test query_graph mock
    with patch("backend.mcp_server.llm_loop.query_graph") as mock_qg:
        mock_qg.return_value = [MagicMock()]
        v_hits, g_hits = _execute_single_tool("query_graph", {"entity_name": "test", "max_hops": 2}, "test_tenant", tool_settings={"file_search_enabled": True})
        assert len(g_hits) == 1
        
    # Test web_search mock
    with patch("backend.mcp_server.tools.web_search.mcp_web_search") as mock_ws:
        mock_ws.return_value = [{"content": "result", "snippet": "snippet", "title": "title", "url": "url"}]
        v_hits, g_hits = _execute_single_tool("web_search", {"query": "test"}, "test_tenant", tool_settings={"web_search": {"enabled": True}})
        assert len(v_hits) == 1
        assert v_hits[0].payload["text"] == "result"

def test_handle_stream_events():
    from backend.mcp_server.llm_loop import _handle_chat_model_end, _handle_chain_end_tools, _handle_chain_end_langgraph
    from langchain_core.messages import AIMessage, ToolMessage
    
    # Test _handle_chat_model_end
    msg = AIMessage(content="", tool_calls=[{"name": "test_tool", "args": {"arg": "val"}, "id": "1"}])
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
    events = _handle_chain_end_langgraph({"data": {"output": {"messages": [msg_with_metrics]}}})
    assert len(events) == 1
    assert events[0]["event"] == "metadata"

def test_helpers():
    from backend.mcp_server.llm_loop import _cosine_similarity, _build_context_string
    
    # Test _cosine_similarity
    assert _cosine_similarity([1, 0], [1, 0]) == 1.0
    assert _cosine_similarity([1, 0], [0, 1]) == 0.0
    assert _cosine_similarity([0, 0], [1, 1]) == 0.0
    
    # Test _build_context_string
    class DummyHit:
        def __init__(self, sources, payload):
            self.sources = sources
            self.payload = payload
            
    res = _build_context_string([
        DummyHit(["source1"], {"text": "hello"}),
        DummyHit(["source2"], {"content": "world"})
    ])
    assert "source1" in res
    assert "hello" in res
    assert "source2" in res
    assert "world" in res

def test_simple_helpers():
    from backend.mcp_server.llm_loop import _apply_observability_settings, _prepend_system_messages
    from langchain_core.messages import HumanMessage, SystemMessage
    
    from unittest.mock import patch
    import os
    
    # Test _apply_observability_settings
    with patch.dict(os.environ, {}):
        _apply_observability_settings({"observability": {"langsmith_enabled": True, "langsmith_api_key": "test_key"}})
        assert os.environ.get("LANGCHAIN_PROJECT") == "Veraxi"
        assert os.environ.get("LANGCHAIN_TRACING_V2") == "true"
    
    # Test _prepend_system_messages
    msgs = [HumanMessage(content="test")]
    new_msgs = _prepend_system_messages(msgs, [SystemMessage(content="sys")])
    assert len(new_msgs) == 3
    assert new_msgs[1].content == "sys"
    assert new_msgs[2].content == "test"
