import json
from types import SimpleNamespace

import pytest
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

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


def test_activity_is_restored_to_final_answers_after_multiple_tool_calls():
    first_activity = [{"number": 1, "name": "First search"}]
    second_activity = [{"number": 1, "name": "Second search"}]
    messages = _extract_messages_from_state(
        [
            AIMessage(
                content="",
                tool_calls=[{"name": "query_graph", "args": {}, "id": "run-1"}],
            ),
            AIMessage(content="first answer"),
            AIMessage(
                content="",
                tool_calls=[{"name": "query_graph", "args": {}, "id": "run-2"}],
            ),
            AIMessage(content="second answer"),
        ],
        activity_history=[first_activity, second_activity],
    )

    answers = [message for message in messages if message["content"]]
    assert [message["activity"] for message in answers] == [
        first_activity,
        second_activity,
    ]


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
async def test_empty_activity_is_saved_to_preserve_response_order():
    class FakeRedis:
        def __init__(self):
            self.values = {}

        async def hget(self, key, field):
            return self.values.get((key, field))

        async def hset(self, key, field, value):
            self.values[(key, field)] = value.encode()

    redis = FakeRedis()
    await _save_activity_history(redis, "tenant-1", "thread-1", [])
    await _save_activity_history(redis, "tenant-1", "thread-1", [{"name": "step-2"}])

    saved = redis.values[("tenant:tenant-1:thread_activities", "thread-1")]
    assert [entry["activity"] for entry in json.loads(saved)] == [
        [],
        [{"name": "step-2"}],
    ]


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


class _FakeRedis:
    def __init__(self):
        self.values = {}

    async def hget(self, key, field):
        return self.values.get((key, field))

    async def hset(self, key, field, value):
        self.values[(key, field)] = value.encode()


def _stream_request():
    return SimpleNamespace(
        question="hello",
        tool_settings=None,
        custom_system_prompt=None,
        is_temporary=False,
        base_url=None,
        calculate_grounding=False,
        model="test-model",
    )


@pytest.mark.asyncio
async def test_save_activity_history_stores_reasoning_when_present():
    redis = _FakeRedis()
    await _save_activity_history(
        redis,
        "tenant-1",
        "thread-1",
        [{"name": "step"}],
        reasoning="deep thought",
        reasoning_duration_seconds=4.2,
    )
    await _save_activity_history(redis, "tenant-1", "thread-1", [{"name": "s2"}])

    saved = json.loads(redis.values[("tenant:tenant-1:thread_activities", "thread-1")])
    assert saved[0]["reasoning"] == "deep thought"
    assert saved[0]["reasoning_duration_seconds"] == 4.2
    # Turns without reasoning keep the legacy entry shape.
    assert "reasoning" not in saved[1]
    assert "reasoning_duration_seconds" not in saved[1]


@pytest.mark.asyncio
async def test_stream_events_persist_reasoning_and_duration():
    from backend.routes.chat import _stream_events

    async def stream_events(*args, **kwargs):
        yield {"event": "on_reasoning_stream", "data": {"text": "deep "}}
        yield {"event": "on_reasoning_stream", "data": {"text": "thought"}}
        yield {"event": "on_reasoning_end", "data": {"seconds": 4.2}}

    redis = _FakeRedis()
    with pytest.MonkeyPatch.context() as monkeypatch:
        monkeypatch.setattr(
            "backend.routes.chat.stream_answer_question", stream_events
        )
        output = [
            chunk
            async for chunk in _stream_events(
                _stream_request(), "tenant-1", "thread-1", "key", None, redis
            )
        ]

    assert output[-1] == "data: [DONE]\n\n"
    saved = json.loads(redis.values[("tenant:tenant-1:thread_activities", "thread-1")])
    assert saved[0]["reasoning"] == "deep thought"
    assert saved[0]["reasoning_duration_seconds"] == 4.2


@pytest.mark.asyncio
async def test_stream_failure_persists_partial_reasoning():
    from backend.routes.chat import _stream_events

    async def stream_events(*args, **kwargs):
        yield {"event": "on_reasoning_stream", "data": {"text": "partial trace"}}
        raise RuntimeError("provider disconnected")

    redis = _FakeRedis()
    with pytest.MonkeyPatch.context() as monkeypatch:
        monkeypatch.setattr(
            "backend.routes.chat.stream_answer_question", stream_events
        )
        output = [
            chunk
            async for chunk in _stream_events(
                _stream_request(), "tenant-1", "thread-1", "key", None, redis
            )
        ]

    assert output[-1] == "data: [DONE]\n\n"
    saved = json.loads(redis.values[("tenant:tenant-1:thread_activities", "thread-1")])
    assert saved[0]["reasoning"] == "partial trace"
    assert "reasoning_duration_seconds" not in saved[0]


@pytest.mark.asyncio
async def test_stream_failure_persists_partial_activity():
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
        raise RuntimeError("provider disconnected")

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
    assert json.loads(saved)[0]["activity"][0]["status"] == "error"


def test_intermediate_tool_message_is_folded_into_final_answer():
    activity = [
        {
            "number": 1,
            "name": "Planning & Discovery",
            "status": "complete",
            "toolEvents": [{"id": "run-1", "name": "create_slide", "isComplete": True}],
        }
    ]
    messages = _extract_messages_from_state(
        [
            HumanMessage(content="create a slide"),
            AIMessage(
                content="",
                tool_calls=[
                    {"name": "create_slide", "args": {"title": "hi"}, "id": "run-1"}
                ],
            ),
            ToolMessage(content="ok", tool_call_id="run-1"),
            AIMessage(content="Here is the artifact block:"),
        ],
        activity_history=[activity],
    )

    assert [m["role"] for m in messages] == ["user", "assistant"]
    assert messages[1]["content"] == "Here is the artifact block:"
    assert messages[1]["activity"] == activity
    assert [e["id"] for e in messages[1]["toolEvents"]] == ["run-1"]


def test_intermediate_tool_message_synthesizes_tool_activity_when_no_history():
    messages = _extract_messages_from_state(
        [
            HumanMessage(content="search"),
            AIMessage(
                content="",
                tool_calls=[
                    {"name": "web_search", "args": {"q": "test"}, "id": "run-1"}
                ],
            ),
            ToolMessage(content="result", tool_call_id="run-1"),
            AIMessage(content="Final answer"),
        ]
    )

    assert [m["role"] for m in messages] == ["user", "assistant"]
    assert messages[1]["activity"][0]["name"] == "Tool activity"
    assert [e["id"] for e in messages[1]["toolEvents"]] == ["run-1"]


def test_orphan_intermediate_tool_message_is_preserved():
    messages = _extract_messages_from_state(
        [
            HumanMessage(content="search"),
            AIMessage(
                content="",
                tool_calls=[{"name": "web_search", "args": {}, "id": "run-1"}],
            ),
        ]
    )

    assert [m["role"] for m in messages] == ["user", "assistant"]
    assert messages[1]["activity"][0]["name"] == "Tool activity"


def test_history_extracts_structured_tool_artifact_instead_of_raw_db_text():
    artifact = [
        {
            "id": "hit-1",
            "payload": {
                "title": "Colette Kress - Wikipedia",
                "url": "https://en.wikipedia.org/wiki/Colette_Kress",
                "text": "Colette Marie Kress is interim CEO.",
            },
            "sources": ["vector"],
        }
    ]
    messages = _extract_messages_from_state(
        [
            HumanMessage(content="whos the ceo of nvidia now?"),
            AIMessage(
                content="",
                tool_calls=[
                    {
                        "name": "web_search",
                        "args": {"query": "nvidia ceo"},
                        "id": "run-1",
                    }
                ],
            ),
            ToolMessage(
                content="Here is the context retrieved from the database:\n[Result 1]: ...",
                tool_call_id="run-1",
                artifact=artifact,
            ),
            AIMessage(content="Colette Kress is interim CEO."),
        ]
    )

    assert [m["role"] for m in messages] == ["user", "assistant"]
    assert messages[1]["toolEvents"][0]["result"] == artifact
    assert messages[1]["activity"][0]["toolEvents"][0]["result"] == artifact
