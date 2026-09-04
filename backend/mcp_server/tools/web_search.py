"""
MCP web search tool — SearXNG search with optional page-content enrichment.

Pipeline:
  1. Query SearXNG → get title, url, content (short snippet per result).
  2. If a scraper is configured in tool_settings, concurrently fetch the top
     N pages and replace `content` with the full extracted text.
  3. Return results to the LLM for synthesis and citation.

IMPORTANT (to LLM): When citing sources in your response, use inline bracketed
citations containing ONLY the source name (e.g. [Yahoo Finance], [Reuters]).
Do not use numbers (like [1]) or markdown hyperlinks.
"""
from __future__ import annotations

import logging

import sentry_sdk

from backend.mcp_server.tools.scrapers import build_scraper
from backend.mcp_server.tools.search_providers import get_search_provider

logger = logging.getLogger(__name__)

# Maximum pages to enrich with full content (caps latency impact).
_DEFAULT_MAX_FETCH = 5
# Total time budget (seconds) shared across all concurrent fetches.
_TOTAL_FETCH_BUDGET = 10.0


def mcp_web_search(
    query: str,
    language: str = "auto",
    max_results: int = 10,
    tool_settings: dict | None = None,
) -> list[dict]:
    """
    Performs a web search using the configured SearXNG instance, then optionally
    enriches results with full page content via the configured scraper strategy.

    IMPORTANT: When citing sources, you MUST use inline bracketed citations containing ONLY the source title EXACTLY as it appears in the results (e.g. `[Yahoo Finance]`, `[Reuters]`). NEVER append URLs next to the citations. NEVER use markdown hyperlinks like `[Title](URL)`. Just use `[Title]`.

    Args:
        query: The search string.
        language: ISO 639-1 language code (e.g. 'en-US', 'es', 'ja') to filter
            results. You MUST detect the language of the user's query and provide
            the specific code to avoid IP-based geolocation issues (the server
            is in Osaka — do not use 'auto' or 'all').
    Returns:
        List of dicts with 'title', 'url', and 'content'.
    """
    tool_settings = tool_settings or {}
    web_settings = tool_settings.get("web_search") or {}

    provider = get_search_provider(web_settings)
    search_results = provider.search(query, language, max_results, web_settings)
    
    if not search_results:
        return []

    return _enrich(search_results, web_settings)


# ── private helpers ────────────────────────────────────────────────────────────


def _enrich(results: list[dict], web_settings: dict) -> list[dict]:
    """
    Optionally replace `content` fields with full page text from the scraper.

    Only enriches the top _DEFAULT_MAX_FETCH results. Keeps the original
    SearXNG snippet for any URL the scraper fails to fetch.
    """
    scraper = build_scraper(web_settings)
    if scraper is None:
        return results

    max_fetch = int(web_settings.get("scraper_max_pages") or _DEFAULT_MAX_FETCH)
    urls_to_fetch = [r["url"] for r in results[:max_fetch] if r.get("url")]

    if not urls_to_fetch:
        return results

    timeout_per_url = _TOTAL_FETCH_BUDGET / max(len(urls_to_fetch), 1)

    try:
        enriched = scraper.fetch_batch(urls_to_fetch, timeout_per_url=timeout_per_url)
    except Exception as exc:  # noqa: BLE001
        # Never let scraping failures break the search result entirely.
        sentry_sdk.capture_exception(exc)
        logger.error("Scraper fetch_batch raised unexpectedly: %s", exc)
        return results

    for result in results:
        url = result.get("url", "")
        full_text = enriched.get(url)
        if full_text:
            # Truncate to 4000 chars to stay within typical context windows
            result["content"] = full_text[:4000]

    return results
