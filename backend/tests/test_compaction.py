"""Manual compaction: splitting, applying, clearing, validation."""

import pytest
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, ToolMessage

from backend.mcp_server import compaction as comp


def _history(turns: int = 6) -> list[BaseMessage]:
    messages: list[BaseMessage] = []
    for i in range(turns):
        messages.append(HumanMessage(content=f"question {i} " * 10))
        messages.append(
            AIMessage(
                content=f"answer {i}",
                tool_calls=[
                    {"name": "search", "args": {}, "id": f"call-{i}", "type": "tool_call"}
                ],
            )
        )
        messages.append(
            ToolMessage(content=f"big result {i} " * 50, tool_call_id=f"call-{i}")
        )
        messages.append(AIMessage(content=f"final answer {i} " * 10))
    return messages


def test_split_keeps_recent_turns_and_never_splits_tool_pairs():
    messages = _history(6)
    pinned, prefix, recent = comp.split_for_compaction(messages, keep_recent_turns=2)
    assert pinned == []
    # Recent starts exactly at a HumanMessage (turn 4 of 6).
    assert isinstance(recent[0], HumanMessage)
    assert "question 4" in str(recent[0].content)
    # Every tool call in recent keeps its ToolMessage in recent.
    recent_tool_ids = {
        m.tool_call_id for m in recent if isinstance(m, ToolMessage)
    }
    recent_call_ids = {
        tc["id"] for m in recent if isinstance(m, AIMessage) for tc in m.tool_calls
    }
    assert recent_call_ids <= recent_tool_ids
    assert len(prefix) + len(recent) == len(messages)


def test_split_with_too_few_turns_compacts_nothing():
    messages = _history(2)
    _, prefix, recent = comp.split_for_compaction(messages, keep_recent_turns=4)
    assert prefix == []
    assert recent == messages


def test_apply_compaction_preserves_prefix_turns_verbatim():
    messages = _history(6)
    new = comp.apply_compaction(messages, "the summary", 2, tokens_before=1000)
    # Recent turns (4 messages x 2 turns) survive untouched at the tail.
    assert new[-8:] == messages[-8:]
    summary_message = new[0]
    assert isinstance(summary_message, HumanMessage)
    assert summary_message.content.startswith(comp.SUMMARY_PREFIX)
    assert "the summary" in summary_message.content
    record = summary_message.additional_kwargs["metrics"]["compaction"]
    assert record["messages_compacted"] == len(messages) - 8
    assert record["tokens_before"] == 1000


def test_apply_compaction_rejects_empty_summary():
    with pytest.raises(comp.CompactionError):
        comp.apply_compaction(_history(6), "   ", 2, tokens_before=100)


def test_minimum_progress_gate():
    comp.check_minimum_progress(1000, 800)  # 20% saved: fine
    with pytest.raises(comp.CompactionError):
        comp.check_minimum_progress(1000, 950)  # 5% saved: refused
    comp.check_minimum_progress(None, None)  # unknown counts: no gate


def test_clear_old_tool_results_only_touches_prefix():
    messages = _history(6)
    new, cleared = comp.clear_old_tool_results(messages, keep_recent_turns=2)
    assert cleared == 4  # one tool result per compacted turn
    prefix_tools = [
        m for m in new[: len(new) - 8] if isinstance(m, ToolMessage)
    ]
    assert all(
        str(m.content).startswith(comp.CLEARED_TOOL_PLACEHOLDER)
        for m in prefix_tools
    )
    # Recent tool results untouched.
    recent_tools = [m for m in new[-8:] if isinstance(m, ToolMessage)]
    assert all("big result" in str(m.content) for m in recent_tools)
    # Idempotent: clearing again clears nothing new.
    _, cleared_again = comp.clear_old_tool_results(new, keep_recent_turns=2)
    assert cleared_again == 0


class _FakeLLM:
    def __init__(self, response):
        self._response = response

    def bind(self, **kwargs):
        return self

    async def ainvoke(self, messages):
        return self._response


@pytest.mark.asyncio
async def test_generate_summary_rejects_truncated_summary(monkeypatch):
    truncated = AIMessage(
        content="## Goal\npartial summary that got cut",
        response_metadata={"finish_reason": "length"},
        usage_metadata={"input_tokens": 10, "output_tokens": comp.SUMMARY_MAX_TOKENS, "total_tokens": 10 + comp.SUMMARY_MAX_TOKENS},
    )
    monkeypatch.setattr(
        "backend.mcp_server.orchestrator._create_chat_llm",
        lambda *a, **k: _FakeLLM(truncated),
    )
    with pytest.raises(comp.CompactionError, match="cut off"):
        await comp.generate_summary(_history(3), "gpt-4o", "key", None)


@pytest.mark.asyncio
async def test_generate_summary_rejects_empty_summary(monkeypatch):
    empty = AIMessage(content="  ", response_metadata={"finish_reason": "stop"})
    monkeypatch.setattr(
        "backend.mcp_server.orchestrator._create_chat_llm",
        lambda *a, **k: _FakeLLM(empty),
    )
    with pytest.raises(comp.CompactionError, match="empty"):
        await comp.generate_summary(_history(3), "gpt-4o", "key", None)


@pytest.mark.asyncio
async def test_generate_summary_returns_text(monkeypatch):
    good = AIMessage(
        content="## Goal\nDo the thing.",
        response_metadata={"finish_reason": "stop"},
        usage_metadata={"input_tokens": 10, "output_tokens": 42, "total_tokens": 52},
    )
    monkeypatch.setattr(
        "backend.mcp_server.orchestrator._create_chat_llm",
        lambda *a, **k: _FakeLLM(good),
    )
    result = await comp.generate_summary(_history(3), "gpt-4o", "key", None)
    assert result == "## Goal\nDo the thing."


def test_find_latest_compaction_locates_summary():
    messages = _history(6)
    new = comp.apply_compaction(messages, "sum", 2, tokens_before=100)
    found = comp.find_latest_compaction(new)
    assert found is not None
    index, record = found
    assert new[index] is new[0]
    assert record["messages_compacted"] > 0
    assert record["restorable"] is True


def test_find_latest_compaction_none_when_uncompacted():
    assert comp.find_latest_compaction(_history(3)) is None


def test_pick_pre_compaction_messages_skips_checkpoints_with_summary():
    messages = _history(6)
    new = comp.apply_compaction(messages, "sum", 2, tokens_before=100)
    _, record = comp.find_latest_compaction(new)
    # History newest-first: current (compacted), a later edit still
    # containing the summary, then the pre-compaction checkpoint.
    later = [*new, HumanMessage(content="after")]
    picked = comp.pick_pre_compaction_messages(
        [new, later, messages], record["compacted_at"]
    )
    assert picked == messages


def test_pick_pre_compaction_messages_none_when_no_older_checkpoint():
    messages = _history(6)
    new = comp.apply_compaction(messages, "sum", 2, tokens_before=100)
    _, record = comp.find_latest_compaction(new)
    assert (
        comp.pick_pre_compaction_messages([new], record["compacted_at"])
        is None
    )
    assert comp.pick_pre_compaction_messages([new], None) is None
