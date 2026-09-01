"""
Scraper strategy factory.

Scrapers enrich SearXNG search results by fetching the actual page content,
giving the LLM the full article text instead of only the ~200-char search snippet.

Dependency direction (per AGENTS.md): mcp_server/tools → (no imports from retrieval/storage)
"""
from backend.mcp_server.tools.scrapers.base import PageScraper, ScraperResult
from backend.mcp_server.tools.scrapers.firecrawl_scraper import FirecrawlScraper
from backend.mcp_server.tools.scrapers.jina_scraper import JinaScraper
from backend.mcp_server.tools.scrapers.trafilatura_scraper import TrafilaturaScraper

__all__ = [
    "PageScraper",
    "ScraperResult",
    "build_scraper",
]


def build_scraper(web_settings: dict) -> "PageScraper | None":
    """
    Factory: returns the appropriate PageScraper based on user tool_settings,
    or None if no scraper is selected (snippet-only mode).

    Args:
        web_settings: the ``tool_settings['web_search']`` dict from the client.
    """
    scraper_name = (web_settings.get("scraper") or "None").strip()

    if scraper_name in ("None", "", "Serper Scrape API", "Tavily Extract API"):
        # Serper/Tavily extract APIs are handled by those providers' search results
        # directly — we don't implement a separate fetch step for them here.
        return None

    if scraper_name == "Trafilatura":
        return TrafilaturaScraper()

    if scraper_name == "Jina Reader":
        api_key = web_settings.get("jina_api_key") or ""
        return JinaScraper(api_key=api_key)

    if scraper_name == "Firecrawl API":
        base_url = web_settings.get("firecrawl_url") or "https://api.firecrawl.dev"
        api_key = web_settings.get("firecrawl_api_key") or ""
        return FirecrawlScraper(base_url=base_url.rstrip("/"), api_key=api_key)

    return None
