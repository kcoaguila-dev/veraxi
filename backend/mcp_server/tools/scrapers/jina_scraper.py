"""
Jina Reader page scraper.

Converts any URL to clean LLM-ready Markdown by prepending the public
Jina Reader endpoint: https://r.jina.ai/{url}

Handles JavaScript-rendered pages. Free tier allows ~20 req/min; providing
an API key raises the limit significantly.

Best for: JS-heavy SPAs, pages that block plain HTTP scrapers, Reddit, Twitter/X.
"""
from __future__ import annotations

import logging
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed, TimeoutError as FuturesTimeoutError

import sentry_sdk

logger = logging.getLogger(__name__)

_JINA_BASE = "https://r.jina.ai"
_MIN_CONTENT_LENGTH = 150


def _fetch_one(url: str, api_key: str, timeout: float) -> tuple[str, str]:
    """Fetch a single URL via Jina Reader. Returns (url, markdown_text)."""
    jina_url = f"{_JINA_BASE}/{url}"
    headers = {
        "Accept": "text/plain",
        "User-Agent": "Veraxi/1.0 (MCP Agent)",
        # Ask Jina to return plain text, not HTML
        "X-Return-Format": "text",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    try:
        req = urllib.request.Request(jina_url, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            text = resp.read().decode("utf-8", errors="replace").strip()
            return url, text
    except urllib.error.HTTPError as exc:
        logger.warning("Jina Reader HTTP %s for %s", exc.code, url)
        return url, ""
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.warning("Jina Reader failed for %s: %s", url, exc)
        return url, ""


class JinaScraper:
    """
    PageScraper implementation backed by the Jina Reader API (r.jina.ai).

    Args:
        api_key: Optional Jina API key. Without it the free (rate-limited) tier is used.
    """

    def __init__(self, api_key: str = "") -> None:
        self._api_key = api_key

    def fetch_batch(
        self,
        urls: list[str],
        timeout_per_url: float = 8.0,
    ) -> dict[str, str]:
        """
        Fetch and extract text for each URL via Jina Reader, concurrently.

        Returns only URLs where extraction produced meaningful content.
        """
        results: dict[str, str] = {}
        if not urls:
            return results

        with ThreadPoolExecutor(max_workers=min(len(urls), 5)) as executor:
            future_to_url = {
                executor.submit(_fetch_one, url, self._api_key, timeout_per_url): url
                for url in urls
            }
            for future in as_completed(future_to_url, timeout=timeout_per_url + 1):
                try:
                    url, content = future.result(timeout=timeout_per_url)
                    if content and len(content) >= _MIN_CONTENT_LENGTH:
                        results[url] = content
                except FuturesTimeoutError:
                    logger.warning("Jina Reader timed out for %s", future_to_url[future])
                except Exception as exc:
                    sentry_sdk.capture_exception(exc)
                    logger.warning("Jina Reader fetch_batch error: %s", exc)

        return results
