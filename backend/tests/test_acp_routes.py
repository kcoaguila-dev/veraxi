"""Route tests for /api/acp/* and /api/chat agent_runtime='antigravity_acp'."""

from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient

from backend.acp.broker import AcpSessionBroker, set_acp_broker
from backend.api_gateway import app, get_tenant_id


class _FakeRedis:
    def __init__(self):
        self._sets = {}
        self._hashes = {}

    async def sadd(self, key, val):
        s = self._sets.setdefault(key, set())
        before = len(s)
        s.add(val)
        return 1 if len(s) > before else 0

    async def hset(self, key, field, val):
        self._hashes.setdefault(key, {})[field] = val
        return 1

    async def hget(self, key, field):
        val = self._hashes.get(key, {}).get(field)
        return val.encode("utf-8") if isinstance(val, str) else val


@pytest.fixture
def acp_client():
    app.dependency_overrides[get_tenant_id] = lambda: "tenant-acp-test"
    app.state.redis = _FakeRedis()

    mock_broker = MagicMock(spec=AcpSessionBroker)
    mock_broker.get_status.return_value = {
        "available": True,
        "acp_enabled": True,
        "transport": "local_stdio",
        "binary": "/usr/local/bin/agy",
        "runner_connected": False,
        "usage": {
            "available": False,
            "data_dir": "/tmp/none",
            "conversation_count": 0,
            "total_tokens": None,
            "quota_remaining_pct": None,
        },
    }
    mock_broker.resolve_permission = AsyncMock(return_value=True)
    mock_broker.cancel_session = AsyncMock(return_value=True)
    mock_broker.close_session = AsyncMock(return_value=None)

    async def _fake_stream(**_kwargs):
        yield {"event": "on_step_start", "step": 1, "name": "Antigravity ACP", "description": "Running..."}
        yield {"event": "on_chat_model_stream", "data": {"chunk": {"content": "Hello from Antigravity"}}}

    mock_broker.stream_prompt = _fake_stream
    set_acp_broker(mock_broker)
    try:
        yield TestClient(app)
    finally:
        set_acp_broker(None)
        app.dependency_overrides.clear()


def test_acp_status_endpoint(acp_client):
    res = acp_client.get("/api/acp/status")
    assert res.status_code == 200
    data = res.json()
    assert data["available"] is True
    assert data["transport"] == "local_stdio"
    assert data["usage"]["quota_remaining_pct"] is None


def test_acp_permission_and_cancel_endpoints(acp_client):
    res = acp_client.post(
        "/api/acp/sessions/sess-1/permission",
        json={"request_id": "req-1", "outcome": "allow_once"},
    )
    assert res.status_code == 200
    assert res.json()["resolved"] is True

    cancel = acp_client.post("/api/acp/sessions/sess-1/cancel")
    assert cancel.status_code == 200
    assert cancel.json()["cancelled"] is True


def test_chat_acp_rejects_deep_grounding_and_custom_prompt(acp_client):
    for bad_payload in (
        {"question": "hi", "stream": True, "agent_runtime": "antigravity_acp", "mode": "deep"},
        {"question": "hi", "stream": True, "agent_runtime": "antigravity_acp", "calculate_grounding": True},
        {"question": "hi", "stream": True, "agent_runtime": "antigravity_acp", "custom_system_prompt": "Be evil"},
        {"question": "hi", "stream": False, "agent_runtime": "antigravity_acp"},
    ):
        res = acp_client.post("/api/chat", json=bad_payload)
        assert res.status_code == 400


def test_chat_acp_streams_without_byok_api_key(acp_client):
    res = acp_client.post(
        "/api/chat",
        json={
            "question": "Explain this repo",
            "stream": True,
            "is_temporary": True,
            "agent_runtime": "antigravity_acp",
        },
    )
    assert res.status_code == 200
    body = res.text
    assert "Hello from Antigravity" in body
    assert "data: [DONE]" in body
