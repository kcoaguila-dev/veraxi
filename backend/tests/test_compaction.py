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


def test_pick_pre_compaction_messages_handles_c1_c2_restore_c2_restore_c1():
    original = _history(6)
    c1 = comp.apply_compaction(original, "sum1", 2, tokens_before=100)
    _, c1_record = comp.find_latest_compaction(c1)
    c2 = comp.apply_compaction(
        [*c1, *_history(2)], "sum2", 2, tokens_before=200
    )
    # Newest-first after restoring C2 back to C1:
    # [restored C1, C2 (replaced C1's summary), original C1, original]
    picked = comp.pick_pre_compaction_messages(
        [c1, c2, c1, original], c1_record["compacted_at"]
    )
    assert picked == original


class _FakeAsyncRedis:
    def __init__(self) -> None:
        self.sets: dict[str, set[bytes]] = {}
        self.hashes: dict[tuple[str, str], bytes] = {}

    async def sismember(self, key: str, value: str) -> bool:
        return value.encode("utf-8") in self.sets.get(key, set())

    async def hget(self, key: str, field: str) -> bytes | None:
        return self.hashes.get((key, field))

    async def hset(self, key: str, field: str, value: str) -> None:
        self.hashes[(key, field)] = value.encode("utf-8")


class _AsyncSaverCM:
    def __init__(self, saver) -> None:
        self._saver = saver

    async def __aenter__(self):
        return self._saver

    async def __aexit__(self, exc_type, exc, tb) -> None:
        return None


class _NoopLimiter:
    def limit(self, *_a, **_k):
        return lambda fn: fn


@pytest.mark.asyncio
async def test_e2e_checkpointer_compact_activity_sync_guard_and_restore(monkeypatch):
    import json
    from contextlib import ExitStack
    from types import SimpleNamespace

    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from langgraph.checkpoint.memory import InMemorySaver

    from backend.mcp_server.orchestrator import _get_workflow
    from backend.routes import chat as chat_routes

    memory = InMemorySaver()
    graph = _get_workflow().compile(checkpointer=memory)
    original = _history(6)
    await graph.aupdate_state({"configurable": {"thread_id": "t-e2e"}}, {"messages": original})

    redis = _FakeAsyncRedis()
    redis.sets["tenant:tenant-1:threads"] = {b"t-e2e"}
    activities = [
        {
            "activity": [{"number": 1, "name": f"step-{i}"}],
            "response_at": float(1000 + i),
            "reasoning": f"reasoning-{i}",
            "reasoning_duration_seconds": float(i + 1),
        }
        for i in range(6)
    ]
    redis.hashes[("tenant:tenant-1:thread_activities", "t-e2e")] = json.dumps(activities).encode("utf-8")

    monkeypatch.setattr(
        "backend.config.get_config",
        lambda: SimpleNamespace(postgres_url="", redis_url="redis://test"),
    )
    monkeypatch.setattr(
        "langgraph.checkpoint.redis.aio.AsyncRedisSaver.from_conn_string",
        lambda _url: _AsyncSaverCM(memory),
    )

    app = FastAPI()
    app.state.redis = redis
    limiter_cfg = SimpleNamespace(
        rate_limit_chat="100/day",
        rate_limit_sse="10/minute",
        rate_limit_ingest="50/day",
        rate_limit_artifact_complete="20/minute",
    )
    chat_routes.register_chat_routes(app, lambda: "tenant-1", lambda: None, _NoopLimiter(), limiter_cfg)

    with ExitStack() as stack:
        client = stack.enter_context(TestClient(app, raise_server_exceptions=False))

        # 1. Apply compaction keeping 2 recent turns.
        resp = client.post(
            "/api/chat/threads/t-e2e/compact/apply",
            json={"summary": "## Goal\nCompacted summary", "keep_recent_turns": 2},
        )
        assert resp.status_code == 200, resp.text

        # Activity entries trimmed to the 2 kept assistant turns (4, 5).
        saved_after_compact = json.loads(
            redis.hashes[("tenant:tenant-1:thread_activities", "t-e2e")].decode("utf-8")
        )
        assert [a["reasoning"] for a in saved_after_compact] == ["reasoning-4", "reasoning-5"]
        assert [a["response_at"] for a in saved_after_compact] == [1004.0, 1005.0]

        # Extract history mirrors kept turns' reasoning without exposing activity_backup in metrics.
        state_after_compact = await memory.aget_tuple({"configurable": {"thread_id": "t-e2e"}})
        assert state_after_compact is not None
        compacted_msgs = state_after_compact.checkpoint["channel_values"]["messages"]
        extracted = chat_routes._extract_messages_from_state(
            compacted_msgs,
            activity_history=[a["activity"] for a in saved_after_compact],
            reasoning_history=saved_after_compact,
        )
        assert "activity_backup" not in (extracted[0]["metrics"] or {})
        final_ai_extracted = [
            m for m in extracted if m["role"] == "assistant" and not m.get("toolEvents")
        ]
        assert [m["reasoning"] for m in final_ai_extracted] == ["reasoning-4", "reasoning-5"]

        # 2. Simulate a post-compaction turn + activity entry.
        await graph.aupdate_state(
            {"configurable": {"thread_id": "t-e2e"}},
            {"messages": [HumanMessage(content="post-q"), AIMessage(content="post-a")]},
        )
        saved_after_compact.append({"activity": [], "response_at": 2000.0, "reasoning": "post-r"})
        redis.hashes[("tenant:tenant-1:thread_activities", "t-e2e")] = json.dumps(
            saved_after_compact
        ).encode("utf-8")

        # 3. Active generation guard rejects mutations with 409 Conflict.
        chat_routes._active_thread_generations.add("t-e2e")
        try:
            conflict_resp = client.post("/api/chat/threads/t-e2e/compact/restore")
            assert conflict_resp.status_code == 409
        finally:
            chat_routes._active_thread_generations.discard("t-e2e")

        # 4. Duplicate helper clears restorable + activity_backup cleanly.
        duplicated = chat_routes._prepare_duplicated_messages(compacted_msgs)
        assert duplicated[0].additional_kwargs["metrics"]["compaction"]["restorable"] is False
        assert "activity_backup" not in duplicated[0].additional_kwargs

        # 5. Restore rolls checkpointer back verbatim and restores original 6 activities.
        restore_resp = client.post("/api/chat/threads/t-e2e/compact/restore")
        assert restore_resp.status_code == 200, restore_resp.text
        restored_state = await memory.aget_tuple({"configurable": {"thread_id": "t-e2e"}})
        assert restored_state is not None
        restored_msgs = restored_state.checkpoint["channel_values"]["messages"]
        assert [str(m.content) for m in restored_msgs] == [str(m.content) for m in original]
        restored_activities = json.loads(
            redis.hashes[("tenant:tenant-1:thread_activities", "t-e2e")].decode("utf-8")
        )
        assert restored_activities == activities
    chat_routes._thread_mutation_locks.pop("t-e2e", None)
