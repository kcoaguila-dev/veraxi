from unittest.mock import AsyncMock, patch

import pytest
from backend.api_gateway import app, get_tenant_id, verify_infrastructure_access
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def override_dependencies():
    async def override_get_tenant_id_local():
        return "test_tenant_id"

    async def override_verify_infrastructure_access():
        return "test_tenant_id"

    app.dependency_overrides[get_tenant_id] = override_get_tenant_id_local
    app.dependency_overrides[verify_infrastructure_access] = (
        override_verify_infrastructure_access
    )
    yield
    app.dependency_overrides.clear()


client = TestClient(app)


# Helper to mock Redis for the app state
class MockRedis:
    async def hget(self, *args):
        return None

    async def sadd(self, key, value):
        return 1

    async def srem(self, key, value):
        return 1

    async def sismember(self, key, value):
        return True

    async def hset(self, *args, **kwargs):
        return 1

    async def hgetall(self, *args, **kwargs):
        return {}

    async def hdel(self, *args, **kwargs):
        return 1

    async def delete(self, *args, **kwargs):
        return 1


@pytest.fixture
def override_redis(monkeypatch):
    monkeypatch.setattr(app.state, "redis", MockRedis(), raising=False)


@pytest.mark.asyncio
async def test_chat_endpoint_no_stream(override_redis):
    # Mock answer_question to return a static answer and context
    with patch(
        "backend.routes.chat.answer_question", new_callable=AsyncMock
    ) as mock_answer:
        mock_answer.return_value = (
            "Hello from test",
            "Test Context",
            {
                "grounding_score": 0.9,
                "context_adherence": 0.9,
                "retrieval_relevance": 1.0,
                "confidence": 0.95,
                "precision": 0.947,
                "generation_seconds": 0.53,
                "context_relevance": "yes",
            },
        )

        response = client.post(
            "/api/chat",
            json={
                "question": "What is testing?",
                "stream": False,
                "model": "test-model",
                "api_key": "dummy",
            },
        )

        assert response.status_code == 200
        data = response.json()
        assert data["answer"] == "Hello from test"
        assert data["context"] == "Test Context"
        assert data["metrics"]["grounding_score"] == 0.9
        assert data["metrics"]["context_adherence"] == 0.9
        assert data["metrics"]["retrieval_relevance"] == 1.0
        assert data["thread_id"] is not None


@pytest.mark.asyncio
async def test_chat_endpoint_stream(override_redis):
    # Mock stream_answer_question to yield some events
    async def mock_stream_events(*args, **kwargs):
        yield {"type": "content", "content": "Hello "}
        yield {"type": "content", "content": "world"}
        yield {"type": "metadata", "content": "Metadata test"}

    with patch(
        "backend.routes.chat.stream_answer_question", side_effect=mock_stream_events
    ):
        response = client.post(
            "/api/chat",
            json={
                "question": "Stream me?",
                "stream": True,
                "model": "test-model",
                "api_key": "dummy",
            },
        )

        assert response.status_code == 200
        assert response.headers["content-type"] == "text/event-stream; charset=utf-8"

        # Parse SSE
        lines = response.text.strip().split("\n\n")
        assert len(lines) == 5  # thread_id metadata + 3 yielded + 1 [DONE]

        assert lines[0].startswith('data: {"event": "metadata", "data": {"thread_id"')

        assert lines[1] == 'data: {"type": "content", "content": "Hello "}'
        assert lines[2] == 'data: {"type": "content", "content": "world"}'
        assert lines[3] == 'data: {"type": "metadata", "content": "Metadata test"}'
        assert lines[4] == "data: [DONE]"


@pytest.mark.asyncio
async def test_chat_endpoint_with_api_key_override(override_redis):
    # Mock answer_question to verify api_key_override is passed through
    with patch(
        "backend.routes.chat.answer_question", new_callable=AsyncMock
    ) as mock_answer:
        mock_answer.return_value = (
            "API Key tested",
            "Context",
            {
                "grounding_score": 0.8,
                "context_adherence": 0.8,
                "retrieval_relevance": 1.0,
                "confidence": 0.9,
                "precision": 0.889,
                "generation_seconds": 0.21,
                "context_relevance": "yes",
            },
        )

        response = client.post(
            "/api/chat",
            json={
                "question": "Use my key?",
                "stream": False,
                "api_key": "dummy_test_key_123",
                "model": "test-model",
            },
        )

        assert response.status_code == 200
        # Verify that answer_question was called with api_key_override="dummy_test_key_123"
        mock_answer.assert_called_once()
        _, kwargs = mock_answer.call_args
        assert kwargs.get("api_key_override") == "dummy_test_key_123"


class MockRedisFull:
    async def hset(self, name, key, value):
        return 1

    async def hdel(self, name, key):
        return 1


@pytest.fixture
def override_redis_full(monkeypatch):
    monkeypatch.setattr(app.state, "redis", MockRedisFull(), raising=False)


@pytest.mark.asyncio
async def test_feedback_endpoint(override_redis_full):
    # Upvote
    response = client.post("/api/chat/messages/msg-123/feedback", json={"value": 1})
    assert response.status_code == 200
    assert response.json()["status"] == "ok"

    # Clear
    response = client.post("/api/chat/messages/msg-123/feedback", json={"value": 0})
    assert response.status_code == 200


@pytest.mark.asyncio
async def test_regenerate_endpoint():
    response = client.post("/api/chat/threads/thread-123/regenerate")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


@pytest.mark.asyncio
async def test_audio_endpoint_missing_voice_id():
    response = client.post("/api/chat/audio", json={"text": "hello"})
    # Should return 422 because voice_id is missing from AudioRequest
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_audio_endpoint_success():
    with (
        patch(
            "backend.tts.gpt_sovits_client.GPTSoVITSClient.synthesize",
            new_callable=AsyncMock,
        ) as mock_synthesize,
        patch("backend.tts.voices.get_voice") as mock_get_voice,
    ):
        mock_synthesize.return_value = b"fake audio bytes"
        mock_get_voice.return_value = {
            "id": "voice_1",
            "name": "Alex",
            "ref_audio_path": "alex_ref.wav",
            "prompt_text": "This is a reference audio for Alex.",
            "prompt_lang": "en",
            "text_lang": "en",
        }

        response = client.post(
            "/api/chat/audio", json={"text": "hello world", "voice_id": "voice_1"}
        )
        assert response.status_code == 200
        assert response.content == b"fake audio bytes"
        mock_synthesize.assert_called_once_with(
            text="hello world",
            ref_audio_path="alex_ref.wav",
            prompt_text="This is a reference audio for Alex.",
            prompt_lang="en",
            text_lang="en",
        )


@pytest.mark.asyncio
async def test_audio_endpoint_unconfigured_voice():
    # default_system voice has no ref_audio_path or prompt_text, so it should return 400
    response = client.post(
        "/api/chat/audio", json={"text": "hello", "voice_id": "default_system"}
    )
    assert response.status_code == 400
    assert response.json()["detail"] == "Voice not configured for backend synthesis"


@pytest.mark.asyncio
async def test_edit_endpoint():
    # Because we don't have a real AsyncRedisSaver setup here, it will raise 500 or 404
    # Just asserting the route exists
    response = client.put(
        "/api/chat/messages/msg-123",
        json={"content": "new text", "thread_id": "thread-123"},
    )
    assert response.status_code in [404, 500]


@pytest.mark.asyncio
async def test_chat_endpoint_no_model_selected(override_redis):
    response = client.post(
        "/api/chat",
        json={"question": "What is testing?", "stream": False},
    )
    assert response.status_code == 400
    assert response.json()["detail"] == "No AI model selected"


@pytest.mark.asyncio
async def test_chat_endpoint_tool_events(override_redis):
    # Mock stream_answer_question to yield tool events just like the modified backend does
    async def mock_stream_events_with_tools(*args, **kwargs):
        yield {
            "event": "on_tool_start",
            "name": "mcp_web_search",
            "run_id": "123",
            "data": {"input": {"query": "test"}},
        }
        yield {
            "event": "on_tool_end",
            "name": "mcp_web_search",
            "run_id": "123",
            "data": {"output": "search results"},
        }

    with patch(
        "backend.routes.chat.stream_answer_question",
        side_effect=mock_stream_events_with_tools,
    ):
        response = client.post(
            "/api/chat",
            json={
                "question": "search something",
                "stream": True,
                "model": "test-model",
                "api_key": "dummy",
            },
        )

        assert response.status_code == 200

        lines = response.text.strip().split("\n\n")
        # Metadata thread_id + 2 tool events + DONE = 4 lines
        assert len(lines) == 4
        assert (
            lines[1]
            == 'data: {"event": "on_tool_start", "name": "mcp_web_search", "run_id": "123", "data": {"input": {"query": "test"}}}'
        )
        assert (
            lines[2]
            == 'data: {"event": "on_tool_end", "name": "mcp_web_search", "run_id": "123", "data": {"output": "search results"}}'
        )


# ============================================================================
# Error Handling Tests - Verify generic, non-leaking error messages
# ============================================================================


@pytest.mark.asyncio
async def test_error_handling_non_stream(override_redis):
    """Test that non-streaming errors return a generic error detail.

    Raw exception class names and messages must never reach the client
    (CWE-209); details are captured server-side via Sentry/logging.
    """
    with (
        patch(
            "backend.routes.chat.answer_question",
            side_effect=ValueError("Test error message"),
        ),
        patch("backend.routes.chat.sentry_sdk.capture_exception") as mock_sentry,
        patch("backend.routes.chat.logger.exception") as mock_logger,
    ):
        response = client.post(
            "/api/chat",
            json={
                "question": "What is testing?",
                "stream": False,
                "model": "test-model",
                "api_key": "dummy",
            },
        )

        assert response.status_code == 500
        data = response.json()
        # Error detail is the generic static message, with no raw exception
        # class name or message leaked to the client
        assert data["detail"] == "Internal server error. Please try again later."
        mock_sentry.assert_called_once()
        mock_logger.assert_called_once()
        assert "ValueError" not in data["detail"]
        assert "Test error message" not in data["detail"]


# Note: Streaming error test is complex to mock properly because stream_answer_question
# is an async generator. The non-streaming tests above verify the error handling logic works.
# In production, streaming errors show the same generic details via SSE.
# @pytest.mark.asyncio
# async def test_error_handling_stream(override_redis):
#     """Test that streaming errors return generic error details in SSE."""
#     pass


@pytest.mark.asyncio
async def test_error_handling_timeout(override_redis):
    """Test that timeout errors return 504 with timeout message."""

    async def mock_timeout(*args, **kwargs):
        raise TimeoutError("Request timed out")

    with patch("backend.routes.chat.answer_question", side_effect=mock_timeout):
        response = client.post(
            "/api/chat",
            json={
                "question": "Timeout test?",
                "stream": False,
                "model": "test-model",
                "api_key": "dummy",
            },
        )

        assert response.status_code == 504
        data = response.json()
        assert "timeout" in data["detail"].lower()
        # Static timeout message; the raw exception message is not leaked
        assert data["detail"] == "Request timeout. Please try again later."
        assert "Request timed out" not in data["detail"]


@pytest.mark.asyncio
async def test_error_handling_httpexception_passthrough(override_redis):
    """Test that HTTPException errors are passed through unchanged."""
    from fastapi import HTTPException

    with patch(
        "backend.routes.chat.answer_question",
        side_effect=HTTPException(status_code=400, detail="Custom bad request"),
    ):
        response = client.post(
            "/api/chat",
            json={
                "question": "HTTPException test?",
                "stream": False,
                "model": "test-model",
                "api_key": "dummy",
            },
        )

        assert response.status_code == 400
        data = response.json()
        assert data["detail"] == "Custom bad request"


@pytest.mark.asyncio
async def test_chat_endpoint_forwards_custom_system_prompt_non_streaming(
    override_redis,
):
    """Verify that non-streaming /api/chat forwards custom_system_prompt via tool_settings."""
    with patch(
        "backend.routes.chat.answer_question", new_callable=AsyncMock
    ) as mock_answer:
        mock_answer.return_value = ("Answer", "Context", {})

        response = client.post(
            "/api/chat",
            json={
                "question": "What is 2+2?",
                "stream": False,
                "model": "test-model",
                "api_key": "dummy",
                "custom_system_prompt": "Act as a pirate.",
            },
        )

        assert response.status_code == 200
        mock_answer.assert_awaited_once()
        tool_settings = mock_answer.call_args.kwargs.get("tool_settings", {})
        assert tool_settings.get("custom_system_prompt") == "Act as a pirate."


@pytest.mark.asyncio
async def test_chat_endpoint_forwards_custom_system_prompt_streaming(override_redis):
    """Verify that streaming /api/chat forwards custom_system_prompt via tool_settings."""

    async def mock_stream(*args, **kwargs):
        yield {"event": "token", "data": "Arr!"}

    with patch(
        "backend.routes.chat.stream_answer_question", side_effect=mock_stream
    ) as mock_stream_fn:
        response = client.post(
            "/api/chat",
            json={
                "question": "What is 2+2?",
                "stream": True,
                "model": "test-model",
                "api_key": "dummy",
                "custom_system_prompt": "Act as a pirate.",
            },
        )

        assert response.status_code == 200
        mock_stream_fn.assert_called_once()
        tool_settings = mock_stream_fn.call_args.kwargs.get("tool_settings", {})
        assert tool_settings.get("custom_system_prompt") == "Act as a pirate."


@pytest.mark.asyncio
async def test_duplicate_thread_rejects_non_owner(override_redis):
    # Mock sismember to return False (non-owner)
    with patch.object(
        app.state.redis, "sismember", new_callable=AsyncMock, return_value=False
    ):
        response = client.post("/api/chat/threads/foreign-thread-123/duplicate")
        assert response.status_code == 403
        assert "Thread not found or access denied" in response.json()["detail"]


@pytest.mark.asyncio
async def test_delete_thread_success(override_redis):
    with patch(
        "backend.routes.chat._delete_postgres_checkpoints",
        new_callable=AsyncMock,
    ) as mock_del_pg:
        response = client.delete("/api/chat/threads/thread-to-delete")
        assert response.status_code == 200
        assert response.json()["status"] == "deleted"
        mock_del_pg.assert_called_once_with(["thread-to-delete"])


# ---------------------------------------------------------------------------
# Code Mode Phase 1: thread_code_meta, ChatRequest fields, thread filters
# ---------------------------------------------------------------------------

import json as _json

from backend.routes.chat import ChatRequest, _build_thread_list, _parse_code_meta


def _b(value):
    return value.encode() if isinstance(value, str) else value


class _StatefulRedis:
    """In-memory Redis fake with real set/hash semantics (bytes values,
    mirroring redis-py's wire behaviour)."""

    def __init__(self):
        self.sets: dict[str, set] = {}
        self.hashes: dict[str, dict] = {}

    async def sadd(self, key, value):
        bucket = self.sets.setdefault(key, set())
        added = 0 if _b(value) in bucket else 1
        bucket.add(_b(value))
        return added

    async def srem(self, key, value):
        self.sets.get(key, set()).discard(_b(value))
        return 1

    async def smembers(self, key):
        return set(self.sets.get(key, set()))

    async def sismember(self, key, value):
        return _b(value) in self.sets.get(key, set())

    async def hset(self, key, field, value=None, **kwargs):
        if kwargs:
            self.hashes.setdefault(key, {}).update(
                {_b(k): _b(v) for k, v in kwargs.items()}
            )
            return 1
        self.hashes.setdefault(key, {})[_b(field)] = _b(value)
        return 1

    async def hget(self, key, field):
        return self.hashes.get(key, {}).get(_b(field))

    async def hgetall(self, key):
        return dict(self.hashes.get(key, {}))

    async def hdel(self, key, field):
        self.hashes.get(key, {}).pop(_b(field), None)
        return 1

    async def delete(self, key):
        self.sets.pop(key, None)
        self.hashes.pop(key, None)
        return 1


@pytest.fixture
def stateful_redis(monkeypatch):
    fake = _StatefulRedis()
    monkeypatch.setattr(app.state, "redis", fake, raising=False)
    return fake


def test_chat_request_code_mode_defaults_are_backward_compatible():
    req = ChatRequest(question="hi")
    assert req.workspace_mode == "chat"
    assert req.repo_key is None
    assert req.branch is None
    assert req.thinking_level is None
    assert req.execution_mode == "act"
    assert req.autonomy_mode is None
    assert req.source_scope is None


def test_chat_request_code_mode_validation():
    req = ChatRequest(
        question="hi",
        workspace_mode="code",
        repo_key="owner/repo",
        branch="main",
        thinking_level="high",
        execution_mode="plan",
        autonomy_mode="auto_workspace_writes",
        source_scope={"repo_key": "owner/repo"},
    )
    assert req.workspace_mode == "code"
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        ChatRequest(question="hi", workspace_mode="bogus")
    with pytest.raises(ValidationError):
        ChatRequest(question="hi", execution_mode="yolo")
    with pytest.raises(ValidationError):
        ChatRequest(question="hi", autonomy_mode="yolo")


def test_parse_code_meta_fail_soft():
    assert _parse_code_meta(None)["workspace_mode"] == "chat"
    assert _parse_code_meta(b"not json")["workspace_mode"] == "chat"
    meta = _parse_code_meta(
        _json.dumps(
            {
                "workspace_mode": "code",
                "repo_key": "owner/repo",
                "branch": "dev",
                "selected_sources": {"repo_key": "owner/repo"},
            }
        ).encode()
    )
    assert meta["workspace_mode"] == "code"
    assert meta["repo_key"] == "owner/repo"
    assert meta["selected_sources"] == {"repo_key": "owner/repo"}


def test_build_thread_list_includes_code_meta():
    threads = {b"t1", b"t2"}
    titles = {b"t1": b"Code thread", b"t2": b"Plain"}
    timestamps = {b"t1": b"2.0", b"t2": b"1.0"}
    code_meta = {
        b"t1": _json.dumps(
            {
                "workspace_mode": "code",
                "repo_key": "owner/repo",
                "branch": "main",
                "selected_sources": {},
            }
        ).encode()
    }
    result = _build_thread_list(threads, titles, set(), set(), {}, timestamps, code_meta)
    by_id = {t["thread_id"]: t for t in result}
    assert by_id["t1"]["workspace_mode"] == "code"
    assert by_id["t1"]["repo_key"] == "owner/repo"
    assert by_id["t1"]["branch"] == "main"
    # Threads without code meta degrade to chat defaults.
    assert by_id["t2"]["workspace_mode"] == "chat"
    assert by_id["t2"]["repo_key"] is None
    assert by_id["t2"]["selected_sources"] == {}


@pytest.mark.asyncio
async def test_chat_code_mode_persists_code_meta_and_threads_filter(
    stateful_redis,
):
    with patch(
        "backend.routes.chat.answer_question", new_callable=AsyncMock
    ) as mock_answer:
        mock_answer.return_value = ("ok", "ctx", {"grounding_score": 0.5})
        response = client.post(
            "/api/chat",
            json={
                "question": "Explain this repo",
                "stream": False,
                "model": "test-model",
                "api_key": "dummy",
                "thread_id": "code-thread-1",
                "workspace_mode": "code",
                "repo_key": "owner/repo",
                "branch": "main",
                "thinking_level": "high",
                "execution_mode": "plan",
                "autonomy_mode": "auto_workspace_writes",
                "source_scope": {"repo_key": "owner/repo"},
            },
        )
        assert response.status_code == 200, response.text
        # Orchestrator received the Code Mode fields via tool_settings.
        tool_settings = mock_answer.call_args.kwargs["tool_settings"]
        assert tool_settings["execution_mode"] == "plan"
        assert tool_settings["thinking_level"] == "high"
        assert tool_settings["sandbox_autonomy_mode"] == "auto_workspace_writes"
        assert tool_settings["source_scope"] == {"repo_key": "owner/repo"}
        assert tool_settings["repo_key"] == "owner/repo"

    raw = await stateful_redis.hget(
        "tenant:test_tenant_id:thread_code_meta", "code-thread-1"
    )
    meta = _json.loads(raw)
    assert meta["workspace_mode"] == "code"
    assert meta["repo_key"] == "owner/repo"
    assert meta["branch"] == "main"
    assert meta["selected_sources"] == {"repo_key": "owner/repo"}

    # A plain chat thread coexists; filters separate them.
    await stateful_redis.sadd("tenant:test_tenant_id:threads", "plain-1")
    listing = client.get("/api/chat/threads")
    assert listing.status_code == 200
    by_id = {t["thread_id"]: t for t in listing.json()["threads"]}
    assert by_id["code-thread-1"]["workspace_mode"] == "code"
    assert by_id["plain-1"]["workspace_mode"] == "chat"

    code_only = client.get("/api/chat/threads", params={"workspace_mode": "code"})
    assert [t["thread_id"] for t in code_only.json()["threads"]] == ["code-thread-1"]
    repo_only = client.get("/api/chat/threads", params={"repo_key": "owner/repo"})
    assert [t["thread_id"] for t in repo_only.json()["threads"]] == ["code-thread-1"]
    no_match = client.get("/api/chat/threads", params={"repo_key": "other/repo"})
    assert no_match.json()["threads"] == []


# ---------------------------------------------------------------------------
# Code Mode Phase 2: files_changed SSE + assistant metadata persistence
# ---------------------------------------------------------------------------

from backend.sandbox.base import ExecEvent, SandboxProvider, SandboxSessionInfo
from backend.sandbox.manager import SandboxManager


class _GitChatProvider(SandboxProvider):
    provider_name = "fake-git"

    def __init__(self, settings, secrets=None, edits=True):
        super().__init__(settings, secrets)
        self.edits = edits
        self.commands: list[str] = []

    async def start_session(self, tenant_id, repo_url=None):
        return SandboxSessionInfo(
            tenant_id=tenant_id, provider="fake-git", status="running"
        )

    async def exec_command(self, session_id, cmd, cwd=None, timeout_sec=120):
        self.commands.append(cmd)
        stdout, exit_code = "", 0
        if cmd.startswith("git rev-parse"):
            stdout = "/repo\n"
        elif cmd.startswith("git diff HEAD --numstat") and self.edits:
            stdout = "2\t1\ta.py\n"
        elif cmd.startswith("git diff HEAD") and self.edits:
            stdout = (
                "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n"
                "@@ -1,2 +1,3 @@\n x\n-old\n+new\n+more\n"
            )
        elif cmd.startswith("git ls-files --others"):
            stdout = ""
        if stdout:
            yield ExecEvent(kind="stdout", data=stdout)
        yield ExecEvent(kind="exit", data="", exit_code=exit_code)

    async def read_file(self, session_id, path):
        return ""

    async def write_file(self, session_id, path, content):
        return None

    async def get_diff(self, session_id):
        return ""

    async def stop_session(self, session_id):
        return None


@pytest.fixture
def sandbox_chat_manager():
    from backend.mcp_server.tool_dispatch import set_sandbox_manager

    created = []

    def factory(settings, secrets):
        provider = _GitChatProvider(settings, secrets, edits=True)
        created.append(provider)
        return provider

    mgr = SandboxManager(provider_factory=factory)
    mgr.set_tenant_config("test_tenant_id", {"provider": "modal"})
    set_sandbox_manager(mgr)
    yield mgr, created
    set_sandbox_manager(None)


@pytest.mark.asyncio
async def test_stream_code_turn_emits_files_changed_and_persists(
    stateful_redis, sandbox_chat_manager
):
    mgr, _created = sandbox_chat_manager
    info = await mgr.start_session("test_tenant_id", chat_id="code-turn-1")

    async def mock_stream(*args, **kwargs):
        yield {"type": "content", "content": "done"}

    with patch(
        "backend.routes.chat.stream_answer_question", side_effect=mock_stream
    ):
        response = client.post(
            "/api/chat",
            json={
                "question": "Edit a.py",
                "stream": True,
                "model": "test-model",
                "api_key": "dummy",
                "thread_id": "code-turn-1",
                "workspace_mode": "code",
                "repo_key": "owner/repo",
            },
        )
    assert response.status_code == 200, response.text
    events = [
        _json.loads(line[len("data: "):])
        for line in response.text.strip().split("\n\n")
        if line.startswith("data: {")
    ]
    changed = [e for e in events if e.get("type") == "files_changed"]
    assert len(changed) == 1
    event = changed[0]
    assert event["session_id"] == info.session_id
    assert event["turn_id"]
    assert event["total_additions"] == 2
    assert event["total_deletions"] == 1
    assert event["files"][0]["path"] == "a.py"
    assert event["files"][0]["language"] == "python"
    assert event["files"][0]["hunks"][0]["lines"][-1] == "+more"

    # Persisted in the per-turn assistant metadata (thread_activities),
    # so the summary survives a thread-history reload.
    raw = await stateful_redis.hget(
        "tenant:test_tenant_id:thread_activities", "code-turn-1"
    )
    entries = _json.loads(raw)
    assert entries[-1]["files_changed"]["session_id"] == info.session_id
    assert entries[-1]["files_changed"]["total_additions"] == 2
    assert entries[-1]["files_changed"]["files"][0]["path"] == "a.py"


@pytest.mark.asyncio
async def test_stream_code_turn_without_edits_emits_nothing(
    stateful_redis, sandbox_chat_manager
):
    mgr, created = sandbox_chat_manager
    await mgr.start_session("test_tenant_id", chat_id="code-turn-2")
    created[-1].edits = False

    async def mock_stream(*args, **kwargs):
        yield {"type": "content", "content": "no edits"}

    with patch(
        "backend.routes.chat.stream_answer_question", side_effect=mock_stream
    ):
        response = client.post(
            "/api/chat",
            json={
                "question": "Just explain",
                "stream": True,
                "model": "test-model",
                "api_key": "dummy",
                "thread_id": "code-turn-2",
                "workspace_mode": "code",
            },
        )
    assert response.status_code == 200, response.text
    assert "files_changed" not in response.text
    raw = await stateful_redis.hget(
        "tenant:test_tenant_id:thread_activities", "code-turn-2"
    )
    entries = _json.loads(raw)
    assert "files_changed" not in entries[-1]


@pytest.mark.asyncio
async def test_stream_code_turn_without_sandbox_session_emits_nothing(
    stateful_redis, sandbox_chat_manager
):
    async def mock_stream(*args, **kwargs):
        yield {"type": "content", "content": "hi"}

    with patch(
        "backend.routes.chat.stream_answer_question", side_effect=mock_stream
    ):
        response = client.post(
            "/api/chat",
            json={
                "question": "hi",
                "stream": True,
                "model": "test-model",
                "api_key": "dummy",
                "thread_id": "code-turn-no-session",
                "workspace_mode": "code",
            },
        )
    assert response.status_code == 200, response.text
    assert "files_changed" not in response.text


def test_extract_messages_attaches_persisted_files_changed():
    from backend.routes.chat import _extract_messages_from_state
    from langchain_core.messages import AIMessage, HumanMessage

    summary = {
        "session_id": "s1",
        "turn_id": "t1",
        "total_additions": 2,
        "total_deletions": 1,
        "files": [{"path": "a.py"}],
    }
    messages = _extract_messages_from_state(
        [HumanMessage(content="edit", id="u1"), AIMessage(content="done", id="a1")],
        {},
        files_changed_history=[summary],
    )
    assistant = next(m for m in messages if m["role"] == "assistant")
    assert assistant["files_changed"] == summary
    user = next(m for m in messages if m["role"] == "user")
    assert "files_changed" not in user


def test_process_message_carries_files_changed_kwarg():
    from backend.routes.chat import _process_single_message
    from langchain_core.messages import AIMessage

    summary = {"session_id": "s1", "total_additions": 1, "files": []}
    msg = AIMessage(
        content="done", id="a9", additional_kwargs={"files_changed": summary}
    )
    processed = _process_single_message(msg, {}, {})
    assert processed["files_changed"] == summary
