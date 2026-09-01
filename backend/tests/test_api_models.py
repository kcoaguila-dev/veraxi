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

    with patch('httpx.AsyncClient.get', side_effect=mock_get):
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
                    {"id": "dall-e-3"}, # Should be filtered out
                    {"id": "whisper-1"} # Should be filtered out
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

    with patch('httpx.AsyncClient.get', side_effect=mock_get):
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

