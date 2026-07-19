from unittest.mock import patch, MagicMock
from backend.mcp_server.tools.web_search import mcp_web_search
import urllib.error
import json

@patch("backend.mcp_server.tools.web_search.get_config")
@patch("backend.mcp_server.tools.web_search.urllib.request.urlopen")
def test_web_search_success(mock_urlopen, mock_get_config):
    # Mock config
    mock_config = MagicMock()
    mock_config.searxng_url = "http://fake-searxng.test/search"
    mock_get_config.return_value = mock_config

    # Mock HTTP response
    mock_response = MagicMock()
    mock_response.status = 200
    fake_data = {
        "results": [
            {"title": "Result 1", "url": "http://1.com", "content": "Content 1"},
            {"title": "Result 2", "url": "http://2.com", "content": "Content 2"}
        ]
    }
    mock_response.read.return_value = json.dumps(fake_data).encode("utf-8")
    
    # Context manager setup for urlopen
    mock_urlopen.return_value.__enter__.return_value = mock_response

    results = mcp_web_search("test query", max_results=2)
    
    assert len(results) == 2
    assert results[0]["title"] == "Result 1"
    assert results[1]["url"] == "http://2.com"


@patch("backend.mcp_server.tools.web_search.get_config")
@patch("backend.mcp_server.tools.web_search.urllib.request.urlopen")
def test_web_search_forbidden_fails_gracefully(mock_urlopen, mock_get_config):
    # Mock config
    mock_config = MagicMock()
    mock_config.searxng_url = "http://fake-searxng.test/search"
    mock_get_config.return_value = mock_config

    # Mock an HTTP 403 Forbidden exception (e.g., JSON format disabled)
    mock_urlopen.side_effect = urllib.error.HTTPError(
        url="http://fake", code=403, msg="Forbidden", hdrs={}, fp=None
    )

    results = mcp_web_search("test query")
    
    # Should safely catch the error and return empty list
    assert results == []


@patch("backend.mcp_server.tools.web_search.get_config")
def test_web_search_no_url_fails_gracefully(mock_get_config):
    # Mock config with empty url
    mock_config = MagicMock()
    mock_config.searxng_url = ""
    mock_get_config.return_value = mock_config

    results = mcp_web_search("test query")
    
    # Should short-circuit and return empty list
    assert results == []
