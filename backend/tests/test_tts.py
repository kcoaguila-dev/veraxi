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


@pytest.mark.asyncio
async def test_fish_audio_adds_model_header_for_free_tier():
    # We want to verify that when no fish_speech_url is provided,
    # the request to api.fish.audio includes the correct 'model' header.

    # We patch httpx.AsyncClient.post
    with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
        # Mock successful response
        mock_post.return_value.status_code = 200
        mock_post.return_value.content = b"fake_audio_bytes"

        response = client.post(
            "/api/chat/audio/fish",
            headers={"x-fish-audio-key": "fake_api_key"},
            json={"text": "Hello world"},
        )

        assert response.status_code == 200

        # Verify httpx.AsyncClient.post was called with the correct target URL and headers
        mock_post.assert_called_once()
        args, kwargs = mock_post.call_args

        assert args[0] == "https://api.fish.audio/v1/tts"
        headers = kwargs.get("headers", {})

        # The key thing we are testing for the 402 bug:
        assert headers.get("model") == "s2.1-pro-free", (
            "The 'model' header must be set to the free tier model string"
        )
        assert headers.get("Authorization") == "Bearer fake_api_key"

        # Ensure 'model' is NOT in the JSON payload
        payload = kwargs.get("json", {})
        assert "model" not in payload, (
            "The 'model' parameter must be passed in the headers, not the JSON payload"
        )
