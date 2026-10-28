"""
Search providers for Veraxi Web Search.

Supports multiple backends (SearXNG, Tavily, DuckDuckGo, Wikipedia) with a unified interface
returning a list of dicts: [{'title': str, 'url': str, 'content': str, 'snippet': str}].

Includes resilient multi-endpoint resolution and fallback chains inspired by AI_PROJECT.
"""

from __future__ import annotations

import json
import logging
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from abc import ABC, abstractmethod

import sentry_sdk

from backend.config import get_config
from backend.mcp_server.tools.scrapers.headers import get_browser_headers
from backend.mcp_server.tools.scrapers.sanitizer import (
    apply_authority_weights,
    is_bot_challenge_or_boilerplate,
)

logger = logging.getLogger(__name__)


class SearchProvider(ABC):
    @abstractmethod
    def search(
        self, query: str, language: str, max_results: int, web_settings: dict
    ) -> list[dict]:
        """Execute search and return standardized results."""


class DuckDuckGoProvider(SearchProvider):
    """
    Zero-key public DuckDuckGo search provider.
    Uses duckduckgo_search (DDGS) with TLS impersonation, with direct HTTP fallback.
    Immune to API quotas and acts as a sovereign zero-key provider.
    """

    def search(
        self, query: str, language: str, max_results: int, web_settings: dict
    ) -> list[dict]:
        clean_query = query.strip()
        results: list[dict] = []

        # 1. Primary: Use duckduckgo_search (DDGS) for rich titles and snippets
        try:
            from duckduckgo_search import DDGS

            region = "wt-wt"
            if language and len(language) == 2:
                region = f"{language.lower()}-{language.lower()}"

            with DDGS() as ddgs:
                raw_hits = list(
                    ddgs.text(clean_query, region=region, max_results=max_results)
                )
                for item in raw_hits:
                    title = item.get("title", "").strip()
                    url = item.get("href", "").strip()
                    snippet = item.get("body", "").strip()
                    if url and (title or snippet):
                        results.append(
                            {
                                "title": title or "Web Source",
                                "url": url,
                                "content": snippet,
                                "snippet": snippet,
                            }
                        )
                if results:
                    return results
        except Exception as exc:
            logger.debug(
                "DDGS query failed or unavailable, falling back to direct parser: %s",
                exc,
            )

        # 2. Resilient Fallback: Direct HTTP search
        encoded = urllib.parse.quote_plus(clean_query)
        url = f"https://html.duckduckgo.com/html/?q={encoded}"

        headers = get_browser_headers()
        req = urllib.request.Request(url, headers=headers)

        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status != 200:
                    return []
                html = resp.read().decode("utf-8", errors="replace")

            snippet_pattern = re.compile(
                r'<a class="result__snippet[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
                re.DOTALL,
            )

            raw_snippets = snippet_pattern.findall(html)
            for link, snippet_raw in raw_snippets[:max_results]:
                clean_snippet = re.sub(r"<[^>]*>", "", snippet_raw).strip()
                clean_snippet = (
                    clean_snippet.replace("&quot;", '"')
                    .replace("&amp;", "&")
                    .replace("&#x27;", "'")
                )
                actual_url = link
                if "uddg=" in link:
                    try:
                        query_params = urllib.parse.parse_qs(
                            urllib.parse.urlparse(link).query
                        )
                        actual_url = query_params.get("uddg", [link])[0]
                    except Exception:
                        actual_url = link

                title = (
                    actual_url.split("/")[-1].replace("-", " ").title() or "Web Source"
                )
                results.append(
                    {
                        "title": title,
                        "url": actual_url,
                        "content": clean_snippet,
                        "snippet": clean_snippet,
                    }
                )
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning("DuckDuckGo direct HTTP search failed: %s", exc)

        return results


class WikipediaProvider(SearchProvider):
    """
    Academic and open knowledge discovery provider via Wikipedia REST API.
    Zero-key, high-veracity, immune to commercial search engine bot blocks.
    Inspired by AI_PROJECT's AcademicAdapter.
    """

    def search(
        self, query: str, language: str, max_results: int, web_settings: dict
    ) -> list[dict]:
        clean_query = query.strip()
        encoded = urllib.parse.quote_plus(clean_query)
        lang_code = language.lower() if language and len(language) == 2 else "en"
        opensearch_url = f"https://{lang_code}.wikipedia.org/w/api.php?action=opensearch&search={encoded}&limit={max_results}&namespace=0&format=json"

        headers = get_browser_headers({"Accept": "application/json"})
        results: list[dict] = []

        try:
            req = urllib.request.Request(opensearch_url, headers=headers)
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status != 200:
                    return []
                data = json.loads(resp.read().decode("utf-8"))

            titles = data[1] if len(data) > 1 else []
            links = data[3] if len(data) > 3 else []

            for title, link in zip(titles, links):
                if len(results) >= max_results:
                    break
                # Fetch structured summary for veracity
                title_encoded = urllib.parse.quote(title.replace(" ", "_"))
                summary_url = f"https://{lang_code}.wikipedia.org/api/rest_v1/page/summary/{title_encoded}"
                try:
                    s_req = urllib.request.Request(summary_url, headers=headers)
                    with urllib.request.urlopen(s_req, timeout=5) as s_resp:
                        if s_resp.status == 200:
                            s_data = json.loads(s_resp.read().decode("utf-8"))
                            extract = s_data.get("extract", "")
                            if extract:
                                results.append(
                                    {
                                        "title": title,
                                        "url": link,
                                        "content": extract,
                                        "snippet": extract,
                                    }
                                )
                except Exception as exc:
                    logger.debug("Failed fetching Wikipedia summary for %s: %s", title, exc)
                    continue
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning("Wikipedia discovery failed: %s", exc)

        return results


class SearXNGProvider(SearchProvider):
    """
    SearXNG private meta-search engine provider.
    Supports confirmed-working engine whitelist and categories (e.g. science, it).
    Applies heritage domain authority weighting and bot-challenge sanitization.
    """

    def search(
        self, query: str, language: str, max_results: int, web_settings: dict
    ) -> list[dict]:
        config = get_config()
        searxng_url = config.searxng_url

        # Allow user to override with their own SearXNG instance
        if web_settings.get("searxng_url"):
            searxng_url = web_settings["searxng_url"]

        if not searxng_url:
            logger.error("SEARXNG_URL is not configured.")
            return []

        # 🛡️ SearXNG Parameter & Category optimization (learned from AI_PROJECT)
        # Avoid combining explicit engines with time_range which zeroes results
        params_dict: dict[str, str] = {
            "q": query,
            "format": "json",
        }

        # Categories support (e.g. 'science' for arXiv/Scholar/PubMed; 'it' for GitHub/StackOverflow)
        if web_settings.get("categories"):
            params_dict["categories"] = web_settings["categories"]
        else:
            # Engines fallback whitelist avoiding CAPTCHA-suspended engines
            params_dict["engines"] = web_settings.get("engines", "google,bing,duckduckgo")

        if language and language.lower() not in ("auto", "all"):
            params_dict["language"] = language
        else:
            # Default to English to prevent geo-IP localized defaults on cloud servers
            params_dict["language"] = "en"

        url = f"{searxng_url}?{urllib.parse.urlencode(params_dict)}"
        results: list[dict] = []

        try:
            req = urllib.request.Request(url, headers=get_browser_headers())
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status != 200:
                    logger.error("SearXNG returned status %s", response.status)
                    return []
                data = json.loads(response.read().decode("utf-8"))
                seen_urls = set()
                for res in data.get("results", []):
                    u = res.get("url", "").strip()
                    content = res.get("content", "").strip()
                    if not u or u in seen_urls:
                        continue
                    # Reject bot challenges in snippets
                    if is_bot_challenge_or_boilerplate(content):
                        continue
                    seen_urls.add(u)
                    results.append(
                        {
                            "title": res.get("title", ""),
                            "url": u,
                            "content": content,
                            "snippet": content,
                            "score": float(res.get("score") or 1.0),
                        }
                    )
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.error("SearXNG search failed: %s", exc)
            return []

        # 🏛️ Apply heritage domain authority weighting (.edu, .gov, arxiv, nature, reuters)
        ranked = apply_authority_weights(results)
        return ranked[:max_results]


class TavilyProvider(SearchProvider):
    def search(
        self, query: str, language: str, max_results: int, web_settings: dict
    ) -> list[dict]:
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
            "include_answer": False,
        }

        json_data = json.dumps(data).encode("utf-8")
        results: list[dict] = []

        headers = get_browser_headers(
            {
                "Content-Type": "application/json",
            }
        )

        try:
            req = urllib.request.Request(
                url,
                data=json_data,
                headers=headers,
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status != 200:
                    logger.error("Tavily returned status %s", response.status)
                    return []
                data = json.loads(response.read().decode("utf-8"))
                for res in data.get("results", []):
                    results.append(
                        {
                            "title": res.get("title", ""),
                            "url": res.get("url", ""),
                            "content": res.get("content", ""),
                            "snippet": res.get("content", ""),
                        }
                    )
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.error("Tavily search failed: %s", exc)
            return []

        return results


def get_search_provider(web_settings: dict) -> SearchProvider:
    """Factory to return the appropriate search provider based on settings."""
    provider_name = web_settings.get("provider", "SearXNG").lower().strip()

    if provider_name == "tavily":
        return TavilyProvider()
    elif provider_name in ("duckduckgo", "ddg"):
        return DuckDuckGoProvider()
    elif provider_name in ("wikipedia", "academic"):
        return WikipediaProvider()

    # Default to SearXNG
    return SearXNGProvider()
