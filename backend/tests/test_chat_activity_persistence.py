import json
from types import SimpleNamespace

import pytest
from langchain_core.messages import AIMessage

from backend.routes.chat import (
    _extract_messages_from_state,
    _record_activity_event,
    _save_activity_history,
)


def test_activity_events_are_restored_on_history_reads():
    activity = []
    _record_activity_event(
        activity,
        {
            "event": "on_step_start",
            "step": 1,
            "name": "Planning",
            "description": "Finding evidence",
        },
    )
    _record_activity_event(
        activity,
        {
            "event": "on_tool_start",
            "run_id": "run-1",
            "name": "query_graph",
            "data": {"input": {"query": "hello"}},
        },
    )
    _record_activity_event(
        activity,
        {
            "event": "on_tool_end",
            "run_id": "run-1",
            "data": {"output": "result"},
            "duration_ms": 42,
        },
    )

    messages = _extract_messages_from_state(
        [
            AIMessage(
                content="",
                tool_calls=[
                    {"name": "query_graph", "args": {"query": "hello"}, "id": "run-1"}
                ],
            ),
            AIMessage(content="answer"),
        ],
        activity_history=[activity],
    )

    assert messages[-1]["activity"][0]["toolEvents"][0]["isComplete"] is True
    assert messages[-1]["activity"][0]["toolEvents"][0]["durationMs"] == 42


@pytest.mark.asyncio
async def test_activity_history_is_appended_per_thread():
    class FakeRedis:
        def __init__(self):
            self.values = {}

        async def hget(self, key, field):
            return self.values.get((key, field))

        async def hset(self, key, field, value):
            self.values[(key, field)] = value.encode()

    redis = FakeRedis()
    await _save_activity_history(redis, "tenant-1", "thread-1", [{"name": "step"}])
    await _save_activity_history(redis, "tenant-1", "thread-1", [{"name": "step-2"}])

    saved = redis.values[("tenant:tenant-1:thread_activities", "thread-1")]
    saved_history = json.loads(saved)
    assert [entry["activity"] for entry in saved_history] == [
        [{"name": "step"}],
        [{"name": "step-2"}],
    ]
    assert all(entry["response_at"] for entry in saved_history)


@pytest.mark.asyncio
async def test_stream_events_persist_activity_before_done():
    from backend.routes.chat import _stream_events

    class FakeRedis:
        def __init__(self):
            self.values = {}

        async def hget(self, key, field):
            return self.values.get((key, field))

        async def hset(self, key, field, value):
            self.values[(key, field)] = value.encode()

    async def stream_events(*args, **kwargs):
        yield {
            "event": "on_step_start",
            "step": 1,
            "name": "Planning",
            "description": "Finding evidence",
        }

    redis = FakeRedis()
    request = SimpleNamespace(
        question="hello",
        tool_settings=None,
        custom_system_prompt=None,
        is_temporary=False,
        base_url=None,
        calculate_grounding=False,
        model="test-model",
    )

    with pytest.MonkeyPatch.context() as monkeypatch:
        monkeypatch.setattr(
            "backend.routes.chat.stream_answer_question", stream_events
        )
        output = [
            chunk
            async for chunk in _stream_events(
                request, "tenant-1", "thread-1", "key", None, redis
            )
        ]

    assert output[-1] == "data: [DONE]\n\n"
    saved = redis.values[("tenant:tenant-1:thread_activities", "thread-1")]
    assert json.loads(saved)[0]["activity"][0]["status"] == "complete"
