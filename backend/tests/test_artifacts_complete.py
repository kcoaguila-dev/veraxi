"""Tests for POST /api/artifacts/complete — the backend of the
in-artifact AI bridge (``window.veraxi.complete``).

The endpoint is a thin, fail-closed shell around
``run_single_completion`` (backend/mcp_server/llm_loop.py): these
tests mock that seam for the HTTP contract (caps, error mapping,
rate limiting, BYOK pass-through) and mock ``_create_chat_llm``
for the helper itself (message order, model defaulting, token
binding). No real provider is ever called.
"""

import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.api_gateway import app, get_tenant_id, verify_infrastructure_access
from backend.config import get_config
from backend.mcp_server.llm_loop import run_single_completion
from backend.routes.artifacts import (
    MAX_COMPLETE_PROMPT_CHARS,
    MAX_COMPLETE_SYSTEM_CHARS,
    _build_artifact_document,
)

OWNER_TENANT = "owner-tenant"

_current_tenant = {"tenant_id": OWNER_TENANT}


@pytest.fixture(autouse=True)
def override_dependencies():
    _current_tenant["tenant_id"] = OWNER_TENANT

    async def override_get_tenant_id():
        return _current_tenant["tenant_id"]

    async def override_verify_infrastructure_access():
        return _current_tenant["tenant_id"]

    app.dependency_overrides[get_tenant_id] = override_get_tenant_id
    app.dependency_overrides[verify_infrastructure_access] = (
        override_verify_infrastructure_access
    )
    yield
    app.dependency_overrides.clear()


@pytest.fixture
def client():
    mock_pool = AsyncMock()
    mock_pool.close = AsyncMock()
    with patch(
        "backend.api_gateway.create_pool", new_callable=AsyncMock
    ) as mock_create_pool:
        mock_create_pool.return_value = mock_pool
        with TestClient(app) as test_client:
            yield test_client


def _headers() -> dict:
    # The gateway's limiter keys on the bearer token, so a fresh
    # token per test keeps the 20/minute buckets isolated.
    return {"Authorization": f"Bearer {uuid.uuid4().hex}"}


def _post(client, body, headers=None):
    return client.post(
        "/api/artifacts/complete",
        json=body,
        headers=headers if headers is not None else _headers(),
    )


# ---------------------------------------------------------------------------
# Happy path + pass-through
# ---------------------------------------------------------------------------


def test_complete_returns_text(client):
    with patch(
        "backend.routes.artifacts.run_single_completion",
        new_callable=AsyncMock,
    ) as mock_run:
        mock_run.return_value = "Hello from the model"
        response = _post(client, {"prompt": "Say hello"})
    assert response.status_code == 200
    assert response.json() == {"text": "Hello from the model"}
    mock_run.assert_awaited_once()
    args, kwargs = mock_run.await_args
    assert args[0] == "Say hello"
    assert kwargs["system"] is None
    assert kwargs["model_override"] is None
    assert kwargs["max_tokens"] == 1024
    assert kwargs["api_key_override"] is None
    assert kwargs["base_url_override"] is None


def test_complete_passes_explicit_fields_through(client):
    with patch(
        "backend.routes.artifacts.run_single_completion",
        new_callable=AsyncMock,
    ) as mock_run:
        mock_run.return_value = "ok"
        response = _post(
            client,
            {
                "prompt": "Summarize",
                "system": "Be terse",
                "model": "some-model",
                "max_tokens": 256,
                "api_key": "user-key",
                "base_url": "http://localhost:9999/v1",
            },
        )
    assert response.status_code == 200
    _, kwargs = mock_run.await_args
    assert kwargs["system"] == "Be terse"
    assert kwargs["model_override"] == "some-model"
    assert kwargs["max_tokens"] == 256
    assert kwargs["api_key_override"] == "user-key"
    assert kwargs["base_url_override"] == "http://localhost:9999/v1"


def test_complete_local_url_header_supplies_base_url_and_dummy_key(client):
    # Mirrors routes/chat.py: a local model gets its endpoint from
    # the x-byod-local-url header and a dummy key when none is sent.
    with patch(
        "backend.routes.artifacts.run_single_completion",
        new_callable=AsyncMock,
    ) as mock_run:
        mock_run.return_value = "ok"
        headers = _headers()
        headers["x-byod-local-url"] = "http://127.0.0.1:8080/v1"
        response = _post(
            client, {"prompt": "Hi", "model": "local-model"}, headers=headers
        )
    assert response.status_code == 200
    _, kwargs = mock_run.await_args
    assert kwargs["base_url_override"] == "http://127.0.0.1:8080/v1"
    assert kwargs["api_key_override"] == "dummy"


def test_complete_ignores_unknown_fields(client):
    # Field whitelist: extra body fields never reach the LLM call.
    with patch(
        "backend.routes.artifacts.run_single_completion",
        new_callable=AsyncMock,
    ) as mock_run:
        mock_run.return_value = "ok"
        response = _post(
            client,
            {"prompt": "Hi", "temperature": 2.0, "tools": ["x"], "stream": True},
        )
    assert response.status_code == 200
    _, kwargs = mock_run.await_args
    assert set(kwargs) == {
        "system",
        "model_override",
        "api_key_override",
        "base_url_override",
        "max_tokens",
    }


# ---------------------------------------------------------------------------
# Caps and validation (fail closed)
# ---------------------------------------------------------------------------


def test_complete_missing_or_empty_prompt_is_400(client):
    for body in ({}, {"prompt": ""}, {"prompt": "   "}, {"prompt": 42}):
        response = _post(client, body)
        assert response.status_code == 400, body


def test_complete_oversize_prompt_and_system_are_413(client):
    response = _post(client, {"prompt": "x" * (MAX_COMPLETE_PROMPT_CHARS + 1)})
    assert response.status_code == 413
    response = _post(
        client,
        {"prompt": "ok", "system": "x" * (MAX_COMPLETE_SYSTEM_CHARS + 1)},
    )
    assert response.status_code == 413


def test_complete_max_tokens_range_is_400(client):
    for bad in (0, -1, 2049, "100", True, 1.5):
        response = _post(client, {"prompt": "Hi", "max_tokens": bad})
        assert response.status_code == 400, bad


def test_complete_non_string_system_and_model_are_400(client):
    assert _post(client, {"prompt": "Hi", "system": 5}).status_code == 400
    assert _post(client, {"prompt": "Hi", "model": ["x"]}).status_code == 400


def test_complete_llm_failure_is_plain_502(client):
    with patch(
        "backend.routes.artifacts.run_single_completion",
        new_callable=AsyncMock,
    ) as mock_run:
        mock_run.side_effect = RuntimeError("provider exploded: secret detail")
        response = _post(client, {"prompt": "Hi"})
    assert response.status_code == 502
    assert response.json()["detail"] == "AI completion failed"
    assert "secret detail" not in response.text


def test_complete_rate_limit_enforced(client):
    headers = _headers()
    with patch(
        "backend.routes.artifacts.run_single_completion",
        new_callable=AsyncMock,
    ) as mock_run:
        mock_run.return_value = "ok"
        statuses = [
            _post(client, {"prompt": "Hi"}, headers=headers).status_code
            for _ in range(21)
        ]
    assert statuses[:20] == [200] * 20
    assert statuses[20] == 429


# ---------------------------------------------------------------------------
# Public pages: the AI stub rejects, and never calls anything
# ---------------------------------------------------------------------------


def test_public_documents_carry_the_disabled_ai_stub():
    for kind, code in (
        ("html", "<p>hi</p>"),
        ("react", "export default function App() { return <div/>; }"),
        ("markdown", "# Title"),
        ("svg", "<svg/>"),
        ("mermaid", "graph TD; A-->B"),
    ):
        document = _build_artifact_document(kind, code)
        assert "AI calls are disabled on public artifacts" in document, kind
        assert "window.claude" in document, kind


# ---------------------------------------------------------------------------
# The helper itself: messages, model defaulting, token binding
# ---------------------------------------------------------------------------


class _FakeLlm:
    def __init__(self, content):
        self._content = content
        self.bound: dict = {}
        self.messages = None

    def bind(self, **kwargs):
        self.bound = kwargs
        return self

    async def ainvoke(self, messages):
        self.messages = messages
        return SimpleNamespace(content=self._content)


@pytest.mark.asyncio
async def test_helper_sends_system_then_prompt_and_binds_tokens():
    fake = _FakeLlm("answer")
    captured = {}

    def factory(model, api_key, base_url=None):
        captured.update(model=model, api_key=api_key, base_url=base_url)
        return fake

    with patch(
        "backend.mcp_server.llm_loop._create_chat_llm", side_effect=factory
    ):
        text = await run_single_completion(
            "Question?",
            system="Be terse",
            model_override="chosen-model",
            api_key_override="k",
            base_url_override="http://x/v1",
            max_tokens=77,
        )
    assert text == "answer"
    assert captured == {
        "model": "chosen-model",
        "api_key": "k",
        "base_url": "http://x/v1",
    }
    assert [type(m).__name__ for m in fake.messages] == [
        "SystemMessage",
        "HumanMessage",
    ]
    assert fake.messages[0].content == "Be terse"
    assert fake.messages[1].content == "Question?"
    assert fake.bound == {"max_tokens": 77}


@pytest.mark.asyncio
async def test_helper_defaults_to_configured_model_without_system():
    fake = _FakeLlm([{"type": "text", "text": "block"}, " text"])
    captured = {}

    def factory(model, api_key, base_url=None):
        captured.update(model=model)
        return fake

    with patch(
        "backend.mcp_server.llm_loop._create_chat_llm", side_effect=factory
    ):
        text = await run_single_completion("Just a prompt")
    # Content blocks normalize to a single string.
    assert text == "block text"
    assert captured["model"] == get_config().llm_model_name
    assert [type(m).__name__ for m in fake.messages] == ["HumanMessage"]
    assert fake.bound == {}
