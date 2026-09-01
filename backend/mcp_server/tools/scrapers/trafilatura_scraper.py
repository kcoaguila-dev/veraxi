"""
Trafilatura-based page scraper.

Uses trafilatura to fetch raw HTML and extract the main article text, stripping
ads, navigation, footers, and other boilerplate. Runs entirely locally — no
external API calls, no rate limits, no JS rendering.

Best for: news sites, blogs, documentation pages (SSR content).
"""
from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from concurrent.futures import TimeoutError as FuturesTimeoutError

import sentry_sdk

logger = logging.getLogger(__name__)

# Minimum character count to consider a fetch successful.
_MIN_CONTENT_LENGTH = 150


def _fetch_one(url: str, timeout: float) -> tuple[str, str]:
    """Fetch and extract a single URL. Returns (url, content)."""
    try:
        # Lazy import: trafilatura is an optional dependency.
        # If not installed the ImportError propagates and is caught by the caller.
        import trafilatura

        html = trafilatura.fetch_url(url, no_ssl=False)
        if not html:
            return url, ""

        text = trafilatura.extract(
            html,
            include_comments=False,
            include_tables=True,
            no_fallback=False,
        )
        return url, (text or "").strip()
    except Exception as exc:  # noqa: BLE001
        sentry_sdk.capture_exception(exc)
        logger.warning("Trafilatura failed for %s: %s", url, exc)
        return url, ""


class TrafilaturaScraper:
    """
    PageScraper implementation backed by Trafilatura.

    Fetches up to len(urls) pages concurrently using a thread pool,
    bounded by timeout_per_url per thread.
    """

    def fetch_batch(
        self,
        urls: list[str],
        timeout_per_url: float = 5.0,
    ) -> dict[str, str]:
        """
        Fetch and extract text for each URL concurrently.

        Returns only URLs where extraction produced at least _MIN_CONTENT_LENGTH chars.
        """
        results: dict[str, str] = {}
        if not urls:
            return results

        with ThreadPoolExecutor(max_workers=min(len(urls), 5)) as executor:
            future_to_url = {
                executor.submit(_fetch_one, url, timeout_per_url): url
                for url in urls
            }
            for future in as_completed(future_to_url, timeout=timeout_per_url + 1):
                try:
                    url, content = future.result(timeout=timeout_per_url)
                    if content and len(content) >= _MIN_CONTENT_LENGTH:
                        results[url] = content
                except FuturesTimeoutError:
                    logger.warning("Trafilatura timed out for %s", future_to_url[future])
                except Exception as exc:  # noqa: BLE001
                    sentry_sdk.capture_exception(exc)
                    logger.warning("Trafilatura fetch_batch error: %s", exc)

        return results
