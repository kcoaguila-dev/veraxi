"""Reasoning traces must survive history reads (web reload), not just live
streaming: <think> extraction in call_model, reasoning + duration on the
history payload, the saved-activity fallback, and the import round-trip."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from langchain_core.messages import AIMessage, HumanMessage

from backend.mcp_server.orchestrator import _extract_think_block, call_model
from backend.routes.chat import (
    ImportedMessage,
    _extract_messages_from_state,
    _to_imported_langchain_messages,
)


@pytest.fixture
def mock_config():
    with patch("backend.mcp_server.orchestrator.get_config") as mock_get_config:
        mock_conf = MagicMock()
        mock_conf.llm_api_key = "test_key"
        mock_conf.llm_model_name = "test_model"
        mock_conf.llm_base_url = "http://test"
        mock_get_config.return_value = mock_conf
        yield mock_conf


def test_extract_think_block_moves_reasoning_and_strips_content():
    msg = AIMessage(content="<think>deep thought</think>Final answer")
    _extract_think_block(msg)
    assert msg.content == "Final answer"
    assert msg.additional_kwargs["reasoning_content"] == "deep thought"


def test_extract_think_block_preserves_surrounding_content():
    msg = AIMessage(content="Before <think>hidden</think> after")
    _extract_think_block(msg)
    assert msg.content == "Before  after"
    assert msg.additional_kwargs["reasoning_content"] == "hidden"


def test_extract_think_block_keeps_existing_reasoning_content():
    msg = AIMessage(
        content="<think>inline</think>Answer",
        additional_kwargs={"reasoning_content": "provider trace"},
    )
    _extract_think_block(msg)
    assert msg.additional_kwargs["reasoning_content"] == "provider trace"


def test_extract_think_block_ignores_unclosed_and_non_string_content():
    unclosed = AIMessage(content="<think>never closed")
    _extract_think_block(unclosed)
    assert unclosed.content == "<think>never closed"
    assert "reasoning_content" not in unclosed.additional_kwargs

    blocks = AIMessage(content=[{"type": "text", "text": "<think>x</think>hi"}])
    _extract_think_block(blocks)
    assert "reasoning_content" not in blocks.additional_kwargs


async def _run_call_model(response):
    plain_llm = AsyncMock()
    plain_llm.ainvoke.return_value = response
    plain_llm.bind_tools = MagicMock(return_value=plain_llm)
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
        state = {
            "messages": [HumanMessage(content="Hello")],
            "calculate_grounding": False,
        }
        result = await call_model(state)
    return result["messages"][0]


@pytest.mark.asyncio
async def test_call_model_persists_think_block_as_reasoning_content(mock_config):
    message = await _run_call_model(
        AIMessage(content="<think>deep thought</think>Final answer")
    )
    assert message.content == "Final answer"
    assert message.additional_kwargs["reasoning_content"] == "deep thought"


@pytest.mark.asyncio
async def test_call_model_without_think_block_adds_no_reasoning(mock_config):
    message = await _run_call_model(AIMessage(content="Plain answer"))
    assert message.content == "Plain answer"
    assert "reasoning_content" not in message.additional_kwargs


def test_history_returns_reasoning_and_duration_from_message_kwargs():
    messages = _extract_messages_from_state(
        [
            AIMessage(
                content="Final answer",
                additional_kwargs={
                    "reasoning_content": "deep thought",
                    "reasoning_duration_seconds": 4.2,
                },
            )
        ]
    )
    assert messages[0]["reasoning"] == "deep thought"
    assert messages[0]["reasoning_duration_seconds"] == 4.2


def test_history_falls_back_to_saved_turn_reasoning():
    messages = _extract_messages_from_state(
        [AIMessage(content="Final answer")],
        reasoning_history=[
            {"reasoning": "saved trace", "reasoning_duration_seconds": 1.5}
        ],
    )
    assert messages[0]["reasoning"] == "saved trace"
    assert messages[0]["reasoning_duration_seconds"] == 1.5


def test_history_prefers_message_reasoning_and_fills_missing_duration():
    messages = _extract_messages_from_state(
        [
            AIMessage(
                content="Final answer",
                additional_kwargs={"reasoning_content": "message trace"},
            )
        ],
        reasoning_history=[
            {"reasoning": "saved trace", "reasoning_duration_seconds": 2.5}
        ],
    )
    assert messages[0]["reasoning"] == "message trace"
    assert messages[0]["reasoning_duration_seconds"] == 2.5


def test_history_without_any_reasoning_returns_none_fields():
    messages = _extract_messages_from_state([AIMessage(content="Answer")])
    assert messages[0]["reasoning"] is None
    assert messages[0]["reasoning_duration_seconds"] is None


def test_imported_message_preserves_reasoning_round_trip():
    imported = _to_imported_langchain_messages(
        [
            ImportedMessage(
                id="m1",
                role="assistant",
                content="Final answer",
                reasoning="deep thought",
                reasoning_duration_seconds=4.2,
            ),
            ImportedMessage(id="m2", role="user", content="Hello"),
        ]
    )
    assert imported[0].additional_kwargs["reasoning_content"] == "deep thought"
    assert imported[0].additional_kwargs["reasoning_duration_seconds"] == 4.2
    assert "reasoning_content" not in imported[1].additional_kwargs

    messages = _extract_messages_from_state(imported)
    assistant = next(m for m in messages if m["role"] == "assistant")
    assert assistant["reasoning"] == "deep thought"
    assert assistant["reasoning_duration_seconds"] == 4.2
