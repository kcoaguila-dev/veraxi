from unittest.mock import AsyncMock, MagicMock, patch

from fastapi.testclient import TestClient

from backend.api_gateway import app
from backend.mcp_server.orchestrator import _create_chat_llm
from backend.thinking_policy import _local_probe_cache


def _mock_response(status_code: int, payload: dict):
    resp = MagicMock()
    resp.status_code = status_code
    resp.json.return_value = payload
    return resp


def test_get_model_capabilities_cloud_models():
    client = TestClient(app)
    res = client.get("/api/models/capabilities")
    assert res.status_code == 200
    data = res.json()

    assert data["gpt-5.4"]["supports_reasoning"] is True
    assert data["gpt-5.4"]["levels"] == ["off", "minimal", "low", "medium", "high", "max"]
    assert data["gpt-4o"]["supports_reasoning"] is False
    assert data["gpt-4o"]["levels"] == []
    assert data["claude-sonnet-4-6"]["mode"] == "adaptive_effort"
    assert data["gemini-3.6-flash"]["mode"] == "level"
    assert data["deepseek-chat"]["mode"] == "toggle"


def test_get_model_capabilities_probes_ollama_and_wires_inference():
    _local_probe_cache.clear()
    client = TestClient(app)

    async def fake_get(url, **kwargs):
        if url.endswith("/models"):
            return _mock_response(200, {"data": [{"id": "my-coder:latest"}]})
        if url.endswith("/api/tags"):
            return _mock_response(200, {"models": [{"name": "my-coder:latest"}]})
        return _mock_response(404, {})

    async def fake_post(url, **kwargs):
        if url.endswith("/api/show"):
            return _mock_response(200, {"capabilities": ["completion", "thinking"]})
        return _mock_response(404, {})

    mock_http = MagicMock()
    mock_http.__aenter__ = AsyncMock(return_value=mock_http)
    mock_http.__aexit__ = AsyncMock(return_value=False)
    mock_http.get = AsyncMock(side_effect=fake_get)
    mock_http.post = AsyncMock(side_effect=fake_post)

    with (
        patch("backend.routes.admin.httpx.AsyncClient", return_value=mock_http),
        patch("backend.thinking_policy.httpx.AsyncClient", return_value=mock_http),
        patch("backend.routes.admin.get_config") as mock_admin_cfg,
        patch("backend.mcp_server.orchestrator.get_config") as mock_cfg,
    ):
        mock_admin_cfg.return_value.is_enterprise = False
        mock_admin_cfg.return_value.llm_api_key = None
        mock_admin_cfg.return_value.llm_base_url = None
        mock_cfg.return_value.is_enterprise = False
        mock_cfg.return_value.llm_api_key = None
        mock_cfg.return_value.llm_base_url = None

        res = client.get(
            "/api/models/capabilities",
            headers={"x-byod-local-url": "http://localhost:11434/v1"},
        )
        assert res.status_code == 200
        data = res.json()
        assert data["local::my-coder:latest"]["supports_reasoning"] is True
        assert data["local::my-coder:latest"]["runtime"] == "ollama"

        # Inference uses the cached probe even for a custom model name
        llm = _create_chat_llm(
            "my-coder:latest",
            api_key=None,
            base_url="http://localhost:11434/v1",
            thinking_level="off",
        )
        assert llm.model == "ollama_chat/my-coder:latest"
        assert llm.model_kwargs == {"reasoning_effort": "none"}


def test_llamacpp_probe_populates_reasoning_budget_on_inference():
    _local_probe_cache.clear()
    client = TestClient(app)

    async def fake_get(url, **kwargs):
        if url.endswith("/models"):
            return _mock_response(200, {"data": [{"id": "qwen3-8b.gguf"}]})
        if url.endswith("/props"):
            return _mock_response(
                200,
                {
                    "chat_template_caps": {
                        "supports_reasoning_effort": True,
                        "supports_thinking": True,
                    }
                },
            )
        return _mock_response(404, {})

    mock_http = MagicMock()
    mock_http.__aenter__ = AsyncMock(return_value=mock_http)
    mock_http.__aexit__ = AsyncMock(return_value=False)
    mock_http.get = AsyncMock(side_effect=fake_get)

    with (
        patch("backend.routes.admin.httpx.AsyncClient", return_value=mock_http),
        patch("backend.thinking_policy.httpx.AsyncClient", return_value=mock_http),
        patch("backend.routes.admin.get_config") as mock_admin_cfg,
        patch("backend.mcp_server.orchestrator.get_config") as mock_cfg,
    ):
        mock_admin_cfg.return_value.is_enterprise = False
        mock_admin_cfg.return_value.llm_api_key = None
        mock_admin_cfg.return_value.llm_base_url = None
        mock_cfg.return_value.is_enterprise = False
        mock_cfg.return_value.llm_api_key = None
        mock_cfg.return_value.llm_base_url = None

        res = client.get(
            "/api/models/capabilities",
            headers={"x-byod-local-url": "http://localhost:8080/v1"},
        )
        assert res.status_code == 200
        assert res.json()["local::qwen3-8b.gguf"]["runtime"] == "llamacpp"

        llm_off = _create_chat_llm(
            "qwen3-8b.gguf",
            api_key=None,
            base_url="http://localhost:8080/v1",
            thinking_level="off",
        )
        assert llm_off.model_kwargs["extra_body"]["reasoning_budget"] == 0

        llm_low = _create_chat_llm(
            "qwen3-8b.gguf",
            api_key=None,
            base_url="http://localhost:8080/v1",
            thinking_level="low",
        )
        assert llm_low.model_kwargs["reasoning_effort"] == "low"
        assert "reasoning_budget" not in llm_low.model_kwargs["extra_body"]


def test_chat_endpoint_rejects_unsupported_thinking_level_strictly():
    from backend.api_gateway import get_tenant_id

    app.dependency_overrides[get_tenant_id] = lambda: "test_tenant"
    try:
        client = TestClient(app)
        res = client.post(
            "/api/chat",
            json={
                "question": "hi",
                "model": "gpt-4o",
                "api_key": "test-key",
                "thinking_level": "high",
            },
        )
        assert res.status_code == 400
        assert "does not support thinking levels" in res.json()["detail"]
    finally:
        app.dependency_overrides.pop(get_tenant_id, None)
