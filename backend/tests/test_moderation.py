import pytest
import httpx
from unittest.mock import patch, MagicMock, AsyncMock
import os

from backend.security.moderation import moderate_text

@pytest.mark.asyncio
async def test_moderate_text_flagged():
    with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
        mock_response = MagicMock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.return_value = {
            "results": [{"flagged": True, "categories": {"hate": True}}]
        }
        mock_post.return_value = mock_response

        result = await moderate_text("bad text", api_key="dummy_key")
        assert result is True

@pytest.mark.asyncio
async def test_moderate_text_safe():
    with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
        mock_response = MagicMock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.return_value = {
            "results": [{"flagged": False}]
        }
        mock_post.return_value = mock_response

        result = await moderate_text("good text", api_key="dummy_key")
        assert result is False

@pytest.mark.asyncio
async def test_moderate_text_fail_open():
    with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
        mock_post.side_effect = httpx.RequestError("Network error")

        # Should catch the error and fail open (return False)
        result = await moderate_text("some text", api_key="dummy_key")
        assert result is False

@pytest.mark.asyncio
async def test_moderate_text_no_key():
    with patch.dict(os.environ, clear=True):
        result = await moderate_text("some text", api_key=None)
        assert result is False
