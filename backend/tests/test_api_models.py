from unittest.mock import patch

import httpx
import pytest
from fastapi.testclient import TestClient

from backend.api_gateway import DEFAULT_PROVIDER_MODELS, app

client = TestClient(app)


@pytest.mark.asyncio
async def test_get_models_fallback():
    # Mock httpx.AsyncClient.get to raise a timeout or error, ensuring fallback logic works
    async def mock_get(*args, **kwargs):
        raise httpx.RequestError("Network error")

    # We also need to clear the in-memory cache if any
    import backend.api_gateway

    backend.api_gateway._cached_models = None
    backend.api_gateway._cached_models_time = 0

    with patch("httpx.AsyncClient.get", side_effect=mock_get):
        response = client.get("/api/models")
        assert response.status_code == 200
        data = response.json()
        assert data == DEFAULT_PROVIDER_MODELS


@pytest.mark.asyncio
async def test_get_models_with_openai_success():
    # Mock successful response from OpenAI
    class MockResponse:
        def __init__(self):
            self.status_code = 200

        def json(self):
            return {
                "data": [
                    {"id": "gpt-4-turbo"},
                    {"id": "gpt-3.5-turbo"},
                    {"id": "o1-mini"},
                    {"id": "dall-e-3"},  # Should be filtered out
                    {"id": "whisper-1"},  # Should be filtered out
                ]
            }

        def raise_for_status(self):
            pass

    async def mock_get(url, *args, **kwargs):
        if "api.openai.com/v1/models" in url:
            return MockResponse()
        raise httpx.RequestError("Other network error")

    # Clear cache
    import backend.api_gateway

    backend.api_gateway._cached_models = None
    backend.api_gateway._cached_models_time = 0

    with patch("httpx.AsyncClient.get", side_effect=mock_get):
        response = client.get("/api/models")
        assert response.status_code == 200
        data = response.json()

        # OpenAI list should come from mock and be filtered
        assert "OpenAI" in data
        assert "gpt-4-turbo" in data["OpenAI"]
        assert "dall-e-3" not in data["OpenAI"]

        # Others should come from fallback
        assert "Anthropic" in data
        assert "DeepSeek" in data


def test_get_models_blocks_ssrf_local_url():
    # Attempting to query cloud metadata via x-byod-local-url must return 400
    response = client.get(
        "/api/models",
        headers={"x-byod-local-url": "http://169.254.169.254/latest/meta-data/"},
    )
    assert response.status_code == 400
    assert "Disallowed provider URL" in response.json()["detail"]


def test_normalize_litellm_model_prefixes():
    from backend.mcp_server.orchestrator import normalize_litellm_model

    # Gemini model without prefix -> gemini/
    model, base_url = normalize_litellm_model("gemini-3.6-flash")
    assert model == "gemini/gemini-3.6-flash"
    assert base_url is None

    # Claude model without prefix -> anthropic/
    model, base_url = normalize_litellm_model("claude-3-5-sonnet-20241022")
    assert model == "anthropic/claude-3-5-sonnet-20241022"
    assert base_url is None

    # DeepSeek model without prefix -> deepseek/
    model, base_url = normalize_litellm_model("deepseek-chat")
    assert model == "deepseek/deepseek-chat"
    assert base_url is None

    # Groq model without prefix -> groq/
    model, base_url = normalize_litellm_model("llama-3.3-70b-versatile")
    assert model == "groq/llama-3.3-70b-versatile"
    assert base_url is None

    # Groq hosts OpenAI-compatible GPT OSS models; do not route them to OpenAI.
    model, base_url = normalize_litellm_model("openai/gpt-oss-20b")
    assert model == "groq/openai/gpt-oss-20b"
    assert base_url is None

    # Already prefixed models remain untouched
    model, base_url = normalize_litellm_model("gemini/gemini-2.5-flash")
    assert model == "gemini/gemini-2.5-flash"
    assert base_url is None

    # Custom local endpoint
    model, base_url = normalize_litellm_model("custom-llm", "http://localhost:11434")
    assert model == "ollama/custom-llm"
    assert base_url == "http://localhost:11434"


def test_create_chat_llm_preserves_byok_api_key():
    from backend.mcp_server.orchestrator import _create_chat_llm

    # Even if is_enterprise is True in config, the per-request BYOK API key must be preserved
    with patch("backend.mcp_server.orchestrator.get_config") as mock_cfg:
        mock_cfg.return_value.is_enterprise = True
        mock_cfg.return_value.llm_api_key = "server-key"
        mock_cfg.return_value.llm_base_url = None

        llm = _create_chat_llm("gemini-3.6-flash", "user-byok-gemini-key")
        assert llm.model == "gemini/gemini-3.6-flash"
        assert llm.api_key == "user-byok-gemini-key"
        assert getattr(llm, "api_base", None) is None


def test_deprecated_groq_model_is_not_selectable():
    assert "llama-3.1-8b-instant" not in DEFAULT_PROVIDER_MODELS["groq"]
    assert "openai/gpt-oss-20b" in DEFAULT_PROVIDER_MODELS["groq"]
