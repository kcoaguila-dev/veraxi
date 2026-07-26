import pytest
from fastapi.testclient import TestClient
from unittest.mock import patch, AsyncMock
from backend.api_gateway import app, get_tenant_id
import json

# Mock the dependency to return a static tenant ID
def override_get_tenant_id():
    return "test_tenant_id"

app.dependency_overrides[get_tenant_id] = override_get_tenant_id

client = TestClient(app)

# Helper to mock Redis for the app state
class MockRedis:
    async def sadd(self, key, value):
        return 1

@pytest.fixture
def override_redis(monkeypatch):
    monkeypatch.setattr(app.state, "redis", MockRedis(), raising=False)

@pytest.mark.asyncio
async def test_chat_endpoint_no_stream(override_redis):
    # Mock answer_question to return a static answer and context
    with patch('backend.api_gateway.answer_question', new_callable=AsyncMock) as mock_answer:
        mock_answer.return_value = ("Hello from test", "Test Context")
        
        response = client.post(
            "/api/chat",
            json={"question": "What is testing?", "stream": False},
        )
        
        assert response.status_code == 200
        data = response.json()
        assert data["answer"] == "Hello from test"
        assert data["context"] == "Test Context"
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
            json={"question": "Stream me?", "stream": True},
        )
        
        assert response.status_code == 200
        assert response.headers["content-type"] == "text/event-stream; charset=utf-8"
        
        # Parse SSE
        lines = response.text.strip().split("\n\n")
        assert len(lines) == 4 # 3 yielded + 1 [DONE]
        
        assert lines[0] == 'data: {"type": "content", "content": "Hello "}'
        assert lines[1] == 'data: {"type": "content", "content": "world"}'
        assert lines[2] == 'data: {"type": "metadata", "content": "Metadata test"}'
        assert lines[3] == 'data: [DONE]'
