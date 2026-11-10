import pytest
from unittest.mock import patch, AsyncMock, MagicMock

from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
from backend.mcp_server.orchestrator import (
    _create_chat_llm,
    call_model,
    normalize_litellm_model,
)
import litellm


@pytest.fixture
def mock_config():
    with patch("backend.mcp_server.orchestrator.get_config") as mock_get_config:
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
        mock_get_config.return_value = mock_conf
        yield mock_conf


@pytest.mark.asyncio
async def test_serializer_level_reasoning_stripping():
    # Test a)
    llm = _create_chat_llm("openai/gpt-oss-20b", "k")

    messages = [
        HumanMessage(content="Hello"),
        AIMessage(content="Hi", additional_kwargs={"reasoning_content": "some trace"}),
    ]

    with patch.object(
        llm.client, "acompletion", new_callable=AsyncMock
    ) as mock_acompletion:
        mock_acompletion.return_value = AsyncMock()
        try:
            await llm.ainvoke(messages)
        except Exception:
            pass

        called_kwargs = mock_acompletion.call_args.kwargs
        sent_messages = called_kwargs.get("messages", [])
        assert len(sent_messages) == 2
        assert "reasoning_content" not in sent_messages[1]


@pytest.mark.asyncio
async def test_serializer_level_reasoning_stripping_with_tools():
    # Test b)
    llm = _create_chat_llm("openai/gpt-oss-20b", "k")

    messages = [
        HumanMessage(content="Hello"),
        AIMessage(
            content="",
            additional_kwargs={
                "reasoning_content": "some trace",
                "tool_calls": [
                    {
                        "id": "t1",
                        "function": {"name": "f1", "arguments": "{}"},
                        "type": "function",
                    }
                ],
            },
        ),
        ToolMessage(content="tool result", tool_call_id="t1"),
    ]

    with patch.object(
        llm.client, "acompletion", new_callable=AsyncMock
    ) as mock_acompletion:
        mock_acompletion.return_value = AsyncMock()
        try:
            await llm.ainvoke(messages)
        except Exception:
            pass

        called_kwargs = mock_acompletion.call_args.kwargs
        sent_messages = called_kwargs.get("messages", [])
        assert len(sent_messages) == 3
        assert "reasoning_content" not in sent_messages[1]


def test_routing_pin():
    # Test c)
    model, base_url = normalize_litellm_model("openai/gpt-oss-20b")
    assert model == "groq/openai/gpt-oss-20b"
    assert base_url is None


@pytest.mark.asyncio
async def test_retry_behavior_non_tool_error(mock_config):
    # Test d)
    mock_llm = AsyncMock()
    # non-tool error
    mock_llm.ainvoke.side_effect = litellm.exceptions.BadRequestError(
        message="some random error", model="model", llm_provider="provider"
    )

    with patch("backend.mcp_server.orchestrator._create_chat_llm") as mock_create:
        mock_create.return_value = mock_llm
        mock_llm.bind_tools.return_value = mock_llm

        state = {
            "messages": [HumanMessage(content="Hello")],
            "calculate_grounding": False,
        }

        with pytest.raises(litellm.exceptions.BadRequestError):
            await call_model(state)

        assert mock_llm.ainvoke.call_count == 1


@pytest.mark.asyncio
async def test_retry_behavior_tool_error(mock_config):
    # Test d) part 2
    mock_llm = AsyncMock()
    # tool error
    mock_llm.ainvoke.side_effect = litellm.exceptions.BadRequestError(
        message="tool failed", model="model", llm_provider="provider"
    )
    # mock fallback
    mock_llm.ainvoke.side_effect = [
        litellm.exceptions.BadRequestError(
            message="tool failed", model="model", llm_provider="provider"
        ),
        litellm.exceptions.BadRequestError(
            message="tool failed", model="model", llm_provider="provider"
        ),
        AIMessage(content="success", additional_kwargs={}),
    ]

    with patch("backend.mcp_server.orchestrator._create_chat_llm") as mock_create:
        mock_create.return_value = mock_llm
        mock_llm.bind_tools.return_value = mock_llm

        state = {
            "messages": [HumanMessage(content="Hello")],
            "calculate_grounding": False,
        }

        await call_model(state)

        assert mock_llm.ainvoke.call_count == 3
