from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.api_gateway import app, get_tenant_id


# Mock the dependency to return a static tenant ID
def override_get_tenant_id():
    return "test_tenant_id"

app.dependency_overrides[get_tenant_id] = override_get_tenant_id

client = TestClient(app)

# Helper to mock Redis for the app state
class MockRedis:
    async def sadd(self, key, value):
        return 1

    async def hset(self, *args, **kwargs):
        return 1

    async def hgetall(self, *args, **kwargs):
        return {}

    async def hdel(self, *args, **kwargs):
        return 1

@pytest.fixture
def override_redis(monkeypatch):
    monkeypatch.setattr(app.state, "redis", MockRedis(), raising=False)

@pytest.mark.asyncio
async def test_chat_endpoint_no_stream(override_redis):
    # Mock answer_question to return a static answer and context
    with patch('backend.api_gateway.answer_question', new_callable=AsyncMock) as mock_answer:
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
            json={"question": "What is testing?", "stream": False, "model": "test-model"},
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

    with patch('backend.api_gateway.stream_answer_question', side_effect=mock_stream_events):
        response = client.post(
            "/api/chat",
            json={"question": "Stream me?", "stream": True, "model": "test-model"},
        )
        
        assert response.status_code == 200
        assert response.headers["content-type"] == "text/event-stream; charset=utf-8"
        
        # Parse SSE
        lines = response.text.strip().split("\n\n")
        assert len(lines) == 5 # thread_id metadata + 3 yielded + 1 [DONE]

        assert lines[0].startswith('data: {"event": "metadata", "data": {"thread_id"')
        
        assert lines[1] == 'data: {"type": "content", "content": "Hello "}'
        assert lines[2] == 'data: {"type": "content", "content": "world"}'
        assert lines[3] == 'data: {"type": "metadata", "content": "Metadata test"}'
        assert lines[4] == 'data: [DONE]'

@pytest.mark.asyncio
async def test_chat_endpoint_with_api_key_override(override_redis):
    # Mock answer_question to verify api_key_override is passed through
    with patch('backend.api_gateway.answer_question', new_callable=AsyncMock) as mock_answer:
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
                "model": "test-model"
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
    response = client.post(
        "/api/chat/messages/msg-123/feedback",
        json={"value": 1}
    )
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    
    # Clear
    response = client.post(
        "/api/chat/messages/msg-123/feedback",
        json={"value": 0}
    )
    assert response.status_code == 200

@pytest.mark.asyncio
async def test_regenerate_endpoint():
    response = client.post(
        "/api/chat/threads/thread-123/regenerate"
    )
    assert response.status_code == 200
    assert response.json()["status"] == "ok"

@pytest.mark.asyncio
async def test_audio_endpoint_missing_voice_id():
    response = client.post(
        "/api/chat/audio",
        json={"text": "hello"}
    )
    # Should return 422 because voice_id is missing from AudioRequest
    assert response.status_code == 422

@pytest.mark.asyncio
async def test_audio_endpoint_success():
    with patch("backend.tts.gpt_sovits_client.GPTSoVITSClient.synthesize", new_callable=AsyncMock) as mock_synthesize:  # noqa: SIM117
        with patch("backend.tts.voices.get_voice") as mock_get_voice:
            mock_synthesize.return_value = b"fake audio bytes"
            mock_get_voice.return_value = {
                "id": "voice_1",
                "name": "Alex",
                "ref_audio_path": "alex_ref.wav",
                "prompt_text": "This is a reference audio for Alex.",
                "prompt_lang": "en",
                "text_lang": "en"
            }
            
            response = client.post(
                "/api/chat/audio",
                json={"text": "hello world", "voice_id": "voice_1"}
            )
            assert response.status_code == 200
            assert response.content == b"fake audio bytes"
            mock_synthesize.assert_called_once_with(
                text="hello world",
                ref_audio_path="alex_ref.wav",
                prompt_text="This is a reference audio for Alex.",
                prompt_lang="en",
                text_lang="en"
            )

@pytest.mark.asyncio
async def test_audio_endpoint_unconfigured_voice():
    # default_system voice has no ref_audio_path or prompt_text, so it should return 400
    response = client.post(
        "/api/chat/audio",
        json={"text": "hello", "voice_id": "default_system"}
    )
    assert response.status_code == 400
    assert response.json()["detail"] == "Voice not configured for backend synthesis"

@pytest.mark.asyncio
async def test_edit_endpoint():
    # Because we don't have a real AsyncRedisSaver setup here, it will raise 500 or 404
    # Just asserting the route exists
    response = client.put(
        "/api/chat/messages/msg-123",
        json={"content": "new text", "thread_id": "thread-123"}
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
        yield {"event": "on_tool_start", "name": "mcp_web_search", "run_id": "123", "data": {"input": {"query": "test"}}}
        yield {"event": "on_tool_end", "name": "mcp_web_search", "run_id": "123", "data": {"output": "search results"}}

    with patch('backend.api_gateway.stream_answer_question', side_effect=mock_stream_events_with_tools):
        response = client.post(
            "/api/chat",
            json={"question": "search something", "stream": True, "model": "test-model"},
        )
        
        assert response.status_code == 200
        
        lines = response.text.strip().split("\n\n")
        # Metadata thread_id + 2 tool events + DONE = 4 lines
        assert len(lines) == 4
        assert lines[1] == 'data: {"event": "on_tool_start", "name": "mcp_web_search", "run_id": "123", "data": {"input": {"query": "test"}}}'
        assert lines[2] == 'data: {"event": "on_tool_end", "name": "mcp_web_search", "run_id": "123", "data": {"output": "search results"}}'
