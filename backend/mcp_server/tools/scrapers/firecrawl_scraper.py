"""
Firecrawl page scraper.

Calls the Firecrawl v1 scrape API to extract clean Markdown from any URL,
including JavaScript-rendered pages. Supports both the managed cloud service
(api.firecrawl.dev) and self-hosted instances.

Enhanced with ScrapeCache deduplication and realistic browser headers.

Best for: production deployments needing reliable JS rendering + anti-bot bypass.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from concurrent.futures import TimeoutError as FuturesTimeoutError

import sentry_sdk
from backend.mcp_server.tools.scrapers.cache import ScrapeCache
from backend.mcp_server.tools.scrapers.headers import get_browser_headers

logger = logging.getLogger(__name__)

_MIN_CONTENT_LENGTH = 150


def _fetch_one(
    url: str, base_url: str, api_key: str, timeout: float
) -> tuple[str, str]:
    """Call Firecrawl scrape endpoint for a single URL. Returns (url, markdown)."""
    endpoint = f"{base_url}/v1/scrape"
    payload = json.dumps({"url": url, "formats": ["markdown"]}).encode()
    headers = get_browser_headers(
        {
            "Content-Type": "application/json",
        }
    )
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    try:
        req = urllib.request.Request(
            endpoint, data=payload, headers=headers, method="POST"
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
            markdown = (
                data.get("data", {}).get("markdown") or data.get("markdown") or ""
            )
            extracted = markdown.strip()
            if extracted and len(extracted) >= _MIN_CONTENT_LENGTH:
                ScrapeCache.set(url, extracted)
            return url, extracted
    except urllib.error.HTTPError as exc:
        logger.warning("Firecrawl HTTP %s for %s", exc.code, url)
        return url, ""
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.warning("Firecrawl failed for %s: %s", url, exc)
        return url, ""


class FirecrawlScraper:
    """
    PageScraper implementation backed by the Firecrawl v1 API.

    Args:
        base_url: Root URL of the Firecrawl instance (no trailing slash).
        api_key: API key. Required for the managed cloud; may be omitted for
                 self-hosted instances with auth disabled.
    """

    def __init__(
        self, base_url: str = "https://api.firecrawl.dev", api_key: str = ""
    ) -> None:
        self._base_url = base_url
        self._api_key = api_key

    def fetch_batch(
        self,
        urls: list[str],
        timeout_per_url: float = 10.0,
    ) -> dict[str, str]:
        """
        Fetch and extract Markdown for each URL via Firecrawl, concurrently.

        Returns only URLs where extraction produced meaningful content.
        """
        results: dict[str, str] = {}
        if not urls:
            return results

        with ThreadPoolExecutor(max_workers=min(len(urls), 5)) as executor:
            future_to_url = {
                executor.submit(
                    _fetch_one, url, self._base_url, self._api_key, timeout_per_url
                ): url
                for url in urls
            }
            try:
                for future in as_completed(future_to_url, timeout=timeout_per_url + 1):
                    try:
                        url, content = future.result(timeout=timeout_per_url)
                        if content and len(content) >= _MIN_CONTENT_LENGTH:
                            results[url] = content
                    except FuturesTimeoutError:
                        logger.warning(
                            "Firecrawl timed out for %s", future_to_url.get(future)
                        )
                    except Exception as exc:
                        sentry_sdk.capture_exception(exc)
                        logger.warning("Firecrawl fetch_batch error: %s", exc)
            except FuturesTimeoutError:
                logger.warning("Firecrawl batch fetch timed out")

        return results
