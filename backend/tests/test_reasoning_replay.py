from unittest.mock import AsyncMock, MagicMock, patch

import pytest

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


async def _captured_messages(messages):
    llm = _create_chat_llm("openai/gpt-oss-20b", "k")
    with patch.object(
        llm.client, "acompletion", new_callable=AsyncMock
    ) as mock_acompletion:
        mock_acompletion.side_effect = RuntimeError("stop after serialization")
        with pytest.raises(RuntimeError, match="stop after serialization"):
            await llm.ainvoke(messages)
        mock_acompletion.assert_called_once()
        return mock_acompletion.call_args.kwargs["messages"]


@pytest.mark.asyncio
async def test_serializer_level_reasoning_stripping():
    sent = await _captured_messages(
        [
            HumanMessage(content="Hello"),
            AIMessage(
                content="Hi", additional_kwargs={"reasoning_content": "some trace"}
            ),
        ]
    )
    assert len(sent) == 2
    assert "reasoning_content" not in sent[1]


@pytest.mark.asyncio
async def test_serializer_level_reasoning_stripping_with_tools():
    sent = await _captured_messages(
        [
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
    )
    assert len(sent) == 3
    assert "reasoning_content" not in sent[1]
    assert sent[1].get("tool_calls")


def test_routing_pin():
    model, base_url = normalize_litellm_model("openai/gpt-oss-20b")
    assert model == "groq/openai/gpt-oss-20b"
    assert base_url is None


def _bad_request(message):
    return litellm.exceptions.BadRequestError(
        message=message, model="model", llm_provider="provider"
    )


def _state():
    return {"messages": [HumanMessage(content="Hello")], "calculate_grounding": False}


async def _run_call_model(side_effect, fallback=None):
    """Run call_model with tools bound; returns (tool_llm, plain_llm)."""
    plain_llm = AsyncMock()
    tool_llm = AsyncMock()
    tool_llm.ainvoke.side_effect = side_effect
    plain_llm.bind_tools = MagicMock(return_value=tool_llm)
    plain_llm.ainvoke.return_value = fallback or AIMessage(content="fallback")
    with (
        patch(
            "backend.mcp_server.orchestrator._create_chat_llm",
            return_value=plain_llm,
        ),
        patch(
            "backend.mcp_server.orchestrator.get_tools",
            new=AsyncMock(return_value=[MagicMock()]),
        ),
    ):
        await call_model(_state())
    return tool_llm, plain_llm


@pytest.mark.asyncio
async def test_non_tool_bad_request_is_not_retried(mock_config):
    plain_llm = AsyncMock()
    tool_llm = AsyncMock()
    tool_llm.ainvoke.side_effect = _bad_request("some random error")
    plain_llm.bind_tools = MagicMock(return_value=tool_llm)
    with (
        patch(
            "backend.mcp_server.orchestrator._create_chat_llm",
            return_value=plain_llm,
        ),
        patch(
            "backend.mcp_server.orchestrator.get_tools",
            new=AsyncMock(return_value=[MagicMock()]),
        ),
        pytest.raises(litellm.exceptions.BadRequestError),
    ):
        await call_model(_state())
    assert tool_llm.ainvoke.call_count == 1
    plain_llm.ainvoke.assert_not_called()


@pytest.mark.asyncio
async def test_unrelated_error_mentioning_function_is_not_retried(mock_config):
    """Substring 'function'/'tool' alone must not trigger retries."""
    plain_llm = AsyncMock()
    tool_llm = AsyncMock()
    tool_llm.ainvoke.side_effect = _bad_request(
        "'reasoning_content' is unsupported for this function-calling model tool"
    )
    plain_llm.bind_tools = MagicMock(return_value=tool_llm)
    with (
        patch(
            "backend.mcp_server.orchestrator._create_chat_llm",
            return_value=plain_llm,
        ),
        patch(
            "backend.mcp_server.orchestrator.get_tools",
            new=AsyncMock(return_value=[MagicMock()]),
        ),
        pytest.raises(litellm.exceptions.BadRequestError),
    ):
        await call_model(_state())
    assert tool_llm.ainvoke.call_count == 1


@pytest.mark.asyncio
async def test_tool_generation_error_is_retried(mock_config):
    err = _bad_request("tool_use_failed: Failed to call a function")
    tool_llm, _ = await _run_call_model(
        [err, err, AIMessage(content="success", additional_kwargs={})]
    )
    assert tool_llm.ainvoke.call_count == 3
