"""
Search providers for Veraxi Web Search.

Supports multiple backends (SearXNG, Tavily) with a unified interface
returning a list of dicts: [{'title': str, 'url': str, 'content': str, 'snippet': str}]
"""
from __future__ import annotations

import json
import logging
import os
import urllib.parse
import urllib.request
from abc import ABC, abstractmethod

import sentry_sdk
from backend.config import get_config

logger = logging.getLogger(__name__)


class SearchProvider(ABC):
    @abstractmethod
    def search(self, query: str, language: str, max_results: int, web_settings: dict) -> list[dict]:
        """Execute search and return standardized results."""


class SearXNGProvider(SearchProvider):
    def search(self, query: str, language: str, max_results: int, web_settings: dict) -> list[dict]:
        config = get_config()
        searxng_url = config.searxng_url

        # Allow user to override with their own SearXNG instance
        if web_settings.get("searxng_url"):
            searxng_url = web_settings["searxng_url"]

        if not searxng_url:
            logger.error("SEARXNG_URL is not configured.")
            return []

        params_dict: dict[str, str] = {
            "q": query,
            "format": "json",
            "engines": "google,bing,duckduckgo",
        }
        if language and language.lower() not in ("auto", "all"):
            params_dict["language"] = language
        else:
            params_dict["language"] = "all"

        url = f"{searxng_url}?{urllib.parse.urlencode(params_dict)}"
        results: list[dict] = []

        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "Veraxi/1.0 (MCP Agent)"}
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status != 200:
                    logger.error("SearXNG returned status %s", response.status)
                    return []
                data = json.loads(response.read().decode("utf-8"))
                for i, res in enumerate(data.get("results", [])):
                    if i >= max_results:
                        break
                    results.append({
                        "title": res.get("title", ""),
                        "url": res.get("url", ""),
                        "content": res.get("content", ""),
                        "snippet": res.get("content", ""),
                    })
        except Exception as exc:  # noqa: BLE001
            sentry_sdk.capture_exception(exc)
            logger.error("SearXNG search failed: %s", exc)
            return []

        return results


class TavilyProvider(SearchProvider):
    def search(self, query: str, language: str, max_results: int, web_settings: dict) -> list[dict]:
        api_key = web_settings.get("api_key") or os.environ.get("TAVILY_API_KEY")
        
        if not api_key:
            logger.error("Tavily API key is not configured in settings or environment.")
            return []
            
        url = "https://api.tavily.com/search"
        data = {
            "api_key": api_key,
            "query": query,
            "search_depth": "basic",
            "max_results": max_results,
            "include_answer": False
        }
        
        json_data = json.dumps(data).encode("utf-8")
        results: list[dict] = []

        try:
            req = urllib.request.Request(
                url, 
                data=json_data,
                headers={
                    "Content-Type": "application/json",
                    "User-Agent": "Veraxi/1.0 (MCP Agent)"
                }
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status != 200:
                    logger.error("Tavily returned status %s", response.status)
                    return []
                data = json.loads(response.read().decode("utf-8"))
                for res in data.get("results", []):
                    results.append({
                        "title": res.get("title", ""),
                        "url": res.get("url", ""),
                        "content": res.get("content", ""),
                        "snippet": res.get("content", ""),
                    })
        except Exception as exc:  # noqa: BLE001
            sentry_sdk.capture_exception(exc)
            logger.error("Tavily search failed: %s", exc)
            return []

        return results


def get_search_provider(web_settings: dict) -> SearchProvider:
    """Factory to return the appropriate search provider based on settings."""
    provider_name = web_settings.get("provider", "SearXNG").lower()
    
    if provider_name == "tavily":
        return TavilyProvider()
    
    # Default to SearXNG
    return SearXNGProvider()
