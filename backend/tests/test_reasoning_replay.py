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


@pytest.mark.asyncio
async def test_transient_rate_limit_retries_without_tool_pollution(mock_config):
    rate_err = litellm.exceptions.RateLimitError(
        message="Rate limit reached. Please try again in 1.65s. https://console.groq.com/settings/billing",
        model="openai/gpt-oss-20b",
        llm_provider="groq",
    )
    sleep_mock = AsyncMock()
    with patch("backend.mcp_server.orchestrator.asyncio.sleep", new=sleep_mock):
        tool_llm, plain_llm = await _run_call_model(
            [rate_err, AIMessage(content="ok", additional_kwargs={})]
        )
    assert tool_llm.ainvoke.call_count == 2
    plain_llm.ainvoke.assert_not_called()
    sleep_mock.assert_awaited_once()
    # Second call should receive the exact original messages (no fake tool-retry prompts)
    first_msgs = tool_llm.ainvoke.call_args_list[0].args[0]
    second_msgs = tool_llm.ainvoke.call_args_list[1].args[0]
    assert len(first_msgs) == len(second_msgs)


@pytest.mark.asyncio
async def test_hard_quota_rate_limit_raises_immediately(mock_config):
    quota_err = litellm.exceptions.RateLimitError(
        message="insufficient_quota: You exceeded your current quota",
        model="openai/gpt-oss-20b",
        llm_provider="groq",
    )
    sleep_mock = AsyncMock()
    plain_llm = AsyncMock()
    tool_llm = AsyncMock()
    tool_llm.ainvoke.side_effect = quota_err
    plain_llm.bind_tools = MagicMock(return_value=tool_llm)
    with (
        patch("backend.mcp_server.orchestrator.asyncio.sleep", new=sleep_mock),
        patch("backend.mcp_server.orchestrator._create_chat_llm", return_value=plain_llm),
        patch(
            "backend.mcp_server.orchestrator.get_tools",
            new=AsyncMock(return_value=[MagicMock()]),
        ),
        pytest.raises(litellm.exceptions.RateLimitError),
    ):
        await call_model(_state())
    assert tool_llm.ainvoke.call_count == 1
    plain_llm.ainvoke.assert_not_called()
    sleep_mock.assert_not_called()


@pytest.mark.asyncio
async def test_midstream_tool_use_failed_value_error_recovers_cleanly(mock_config):
    midstream_err = ValueError("invalid literal for int() with base 10: 'tool_use_failed'")
    tool_llm, plain_llm = await _run_call_model(
        [midstream_err, midstream_err, midstream_err]
    )
    assert tool_llm.ainvoke.call_count == 3
    plain_llm.ainvoke.assert_awaited_once()
    fallback_msgs = plain_llm.ainvoke.call_args.args[0]
    assert all(
        "Your previous tool call failed" not in str(m.content) for m in fallback_msgs
    )


def test_friendly_provider_error_maps_tool_use_failed():
    from backend.routes.chat import _friendly_provider_error

    msg = _friendly_provider_error(
        ValueError("invalid literal for int() with base 10: 'tool_use_failed'")
    )
    assert "tool-calling error" in msg
    assert "ValueError" not in msg


@pytest.mark.asyncio
async def test_after_tool_synthesis_strips_tool_protocol_and_recovers(mock_config):
    plain_llm = AsyncMock()
    tool_llm = AsyncMock()
    plain_llm.bind_tools = MagicMock(return_value=tool_llm)
    plain_llm.ainvoke.side_effect = [
        ValueError("invalid literal for int() with base 10: 'tool_use_failed'"),
        AIMessage(content="Colette Kress is interim CEO."),
    ]
    state = {
        "messages": [
            HumanMessage(content="whos the ceo of nvidia now?"),
            AIMessage(
                content="",
                tool_calls=[
                    {
                        "name": "web_search",
                        "args": {"query": "nvidia ceo"},
                        "id": "call-1",
                    }
                ],
            ),
            ToolMessage(
                content="Here is the context retrieved from the database:\n[Result 1]: Colette Kress",
                tool_call_id="call-1",
            ),
        ],
        "calculate_grounding": False,
        "tool_settings": {"web_search": {"enabled": True}},
    }

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
        result = await call_model(state)

    assert result["messages"][0].content == "Colette Kress is interim CEO."
    assert plain_llm.ainvoke.call_count == 2
    tool_llm.ainvoke.assert_not_called()

    first_sent = plain_llm.ainvoke.call_args_list[0].args[0]
    assert all(not isinstance(m, ToolMessage) for m in first_sent)
    assert all(not getattr(m, "tool_calls", None) for m in first_sent)
    system_text = "\n".join(str(m.content) for m in first_sent)
    assert "you MUST call the retrieval tools again" not in system_text
    assert "do NOT attempt to call or invoke any tools" in system_text


@pytest.mark.asyncio
async def test_after_tool_synthesis_recovers_from_tool_choice_none_bad_request(
    mock_config,
):
    plain_llm = AsyncMock()
    plain_llm.bind_tools = MagicMock(return_value=AsyncMock())
    plain_llm.ainvoke.side_effect = [
        _bad_request("Tool choice is none, but model called a tool"),
        AIMessage(content="Recovered answer."),
    ]
    state = {
        "messages": [
            HumanMessage(content="hello"),
            ToolMessage(content="context", tool_call_id="c1"),
        ],
        "calculate_grounding": False,
    }
    with patch(
        "backend.mcp_server.orchestrator._create_chat_llm",
        return_value=plain_llm,
    ):
        result = await call_model(state)

    assert result["messages"][0].content == "Recovered answer."
    assert plain_llm.ainvoke.call_count == 2
