"""End-to-end tests for error handling in chat endpoints.

These tests verify that errors in multi-turn conversations and other
scenarios return specific, actionable error messages instead of generic
"An internal error occurred" messages.
"""

from unittest.mock import AsyncMock, patch

import pytest
from backend.api_gateway import app, get_tenant_id, verify_infrastructure_access
from fastapi.testclient import TestClient

# Global test client - same pattern as test_api_chat.py
client = TestClient(app)


# Mock Redis class - extended from test_api_chat.py to include all needed methods
class MockRedis:
    async def sadd(self, key, value):
        return 1

    async def hset(self, *args, **kwargs):
        return 1

    async def hgetall(self, *args, **kwargs):
        return {}

    async def hdel(self, *args, **kwargs):
        return 1
    
    async def get(self, *args, **kwargs):
        return None
    
    async def smembers(self, *args, **kwargs):
        return set()
    
    async def sismember(self, *args, **kwargs):
        return True


@pytest.fixture(autouse=True)
def override_dependencies():
    """Override auth dependencies for testing - same as test_api_chat.py."""
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


@pytest.fixture
def override_redis(monkeypatch):
    """Mock Redis for the app state - same as test_api_chat.py."""
    monkeypatch.setattr(app.state, "redis", MockRedis(), raising=False)


class TestMultiTurnConversationErrors:
    """Test error handling in multi-turn conversations."""

    @patch("backend.routes.chat.answer_question")
    @patch('backend.routes.chat.sentry_sdk.capture_exception')
    def test_multiturn_error_non_streaming(self, mock_sentry, mock_answer, override_redis):
        """Test that errors in second turn of conversation return specific details."""
        # First message succeeds
        mock_answer.return_value = ("First response", "context", {})
        response1 = client.post(
            "/api/chat",
            json={"question": "First message", "stream": False, "model": "gpt-4o", "api_key": "dummy"},
        )
        assert response1.status_code == 200
        thread_id = response1.json()["thread_id"]

        # Second message fails with an exception
        mock_answer.side_effect = ValueError("Database connection failed")
        response2 = client.post(
            "/api/chat",
            json={
                "question": "Second message",
                "stream": False,
                "model": "gpt-4o", "api_key": "dummy",
                "thread_id": thread_id,
            },
        )

        assert response2.status_code == 500
        data = response2.json()
        assert "Internal server error" in data["detail"]
        mock_sentry.assert_called_once()
        mock_sentry.assert_called_once()
        assert "ValueError" in data["detail"]
        assert "Database connection failed" in data["detail"]


class TestErrorMessageSpecificity:
    """Test that different error types return appropriate messages."""

    @patch("backend.routes.chat.answer_question")
    @patch('backend.routes.chat.sentry_sdk.capture_exception')
    def test_key_error_returns_details(self, mock_sentry, mock_answer, override_redis):
        """Test that KeyError returns the missing key in error message."""
        mock_answer.side_effect = KeyError("messages")
        response = client.post(
            "/api/chat",
            json={"question": "Test", "stream": False, "model": "gpt-4o", "api_key": "dummy"},
        )

        assert response.status_code == 500
        data = response.json()
        assert "KeyError" in data["detail"]
        assert "messages" in data["detail"]

    @patch("backend.routes.chat.answer_question")
    @patch('backend.routes.chat.sentry_sdk.capture_exception')
    def test_type_error_returns_details(self, mock_sentry, mock_answer, override_redis):
        """Test that TypeError returns the type mismatch in error message."""
        mock_answer.side_effect = TypeError("Expected str, got NoneType")
        response = client.post(
            "/api/chat",
            json={"question": "Test", "stream": False, "model": "gpt-4o", "api_key": "dummy"},
        )

        assert response.status_code == 500
        data = response.json()
        assert "TypeError" in data["detail"]
        assert "Expected str, got NoneType" in data["detail"]

    @patch("backend.routes.chat.answer_question")
    @patch('backend.routes.chat.sentry_sdk.capture_exception')
    def test_attribute_error_returns_details(self, mock_sentry, mock_answer, override_redis):
        """Test that AttributeError returns the missing attribute in error message."""
        mock_answer.side_effect = AttributeError("'NoneType' object has no attribute 'content'")
        response = client.post(
            "/api/chat",
            json={"question": "Test", "stream": False, "model": "gpt-4o", "api_key": "dummy"},
        )

        assert response.status_code == 500
        data = response.json()
        assert "AttributeError" in data["detail"]
        assert "'NoneType' object has no attribute 'content'" in data["detail"]


class TestThreadOperationsErrorHandling:
    """Test error handling in thread-related operations."""

    @patch('backend.routes.chat.sentry_sdk.capture_exception')
    def test_list_threads_error(self, mock_sentry, override_redis):
        """Test that list threads endpoint returns specific errors."""
        # Get the mock Redis instance from app.state
        mock_redis = app.state.redis
        mock_redis.smembers = AsyncMock(side_effect=ConnectionError("Redis connection failed"))
        
        response = client.get("/api/chat/threads")

        assert response.status_code == 500
        data = response.json()
        assert "Internal server error" in data["detail"]
        mock_sentry.assert_called_once()
        mock_sentry.assert_called_once()
        assert "ConnectionError" in data["detail"]

    @patch('backend.routes.chat.sentry_sdk.capture_exception')
    def test_get_thread_history_error(self, mock_sentry, override_redis):
        """Test that get thread history endpoint returns specific errors."""
        # Get the mock Redis instance from app.state
        mock_redis = app.state.redis
        mock_redis.sismember = AsyncMock(side_effect=ValueError("Invalid thread ID format"))
        
        response = client.get("/api/chat/threads/nonexistent-thread")

        assert response.status_code == 500
        data = response.json()
        assert "Internal server error" in data["detail"]
        mock_sentry.assert_called_once()
        mock_sentry.assert_called_once()
        assert "ValueError" in data["detail"]
