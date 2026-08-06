import json
import sentry_sdk
import logging
import urllib.request
import urllib.parse
from backend.config import get_config

logger = logging.getLogger(__name__)

def mcp_web_search(query: str, language: str = "auto", max_results: int = 10, tool_settings: dict | None = None) -> list[dict]:
    """
    Performs a web search using the configured SearXNG instance.
    Args:
        query: The search string.
        language: ISO 639-1 language code (e.g. 'en', 'es', 'ja') to filter results, or 'auto' to search across all languages.
    Returns a list of dictionaries containing 'title', 'url', and 'content'.
    """
    config = get_config()
    searxng_url = config.searxng_url

    tool_settings = tool_settings or {}
    web_settings = tool_settings.get("web_search") or {}
    if web_settings.get("provider") == "SearXNG" and web_settings.get("searxng_url"):
        searxng_url = web_settings.get("searxng_url")

    if not searxng_url:
        logger.error("SEARXNG_URL is not configured.")
        return []

    # Prepare query parameters
    params_dict = {
        'q': query,
        'format': 'json',
        'engines': 'google,bing,duckduckgo'
    }
    if language and language.lower() != "auto":
        params_dict['language'] = language
    else:
        params_dict['language'] = 'all'

    params = urllib.parse.urlencode(params_dict)
    
    url = f"{searxng_url}?{params}"
    results = []
    
    try:
        req = urllib.request.Request(
            url, 
            headers={'User-Agent': 'Veraxi/1.0 (MCP Agent)'}
        )
        with urllib.request.urlopen(req, timeout=10) as response:
            if response.status == 200:
                data = json.loads(response.read().decode('utf-8'))
                
                # Parse SearXNG results format
                for i, res in enumerate(data.get('results', [])):
                    if i >= max_results:
                        break
                    
                    results.append({
                        'title': res.get('title', ''),
                        'url': res.get('url', ''),
                        'content': res.get('content', '')
                    })
            else:
                logger.error(f"SearXNG returned status code {response.status}")
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Error during SearXNG web search: {e}")
        # Return empty list so the orchestrator handles fallback gracefully
        return []
    
    return results
