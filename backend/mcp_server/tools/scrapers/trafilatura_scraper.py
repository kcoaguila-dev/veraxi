"""
Trafilatura-based page scraper.

Uses trafilatura to fetch raw HTML and extract the main article text, stripping
ads, navigation, footers, and other boilerplate. Runs entirely locally — no
external API calls, no rate limits, no JS rendering.

Enhanced with RobotsGate crawl-delay pacing and ScrapeCache deduplication
to prevent IP bans and repetitive network hits.

Best for: news sites, blogs, documentation pages (SSR content).
"""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from concurrent.futures import TimeoutError as FuturesTimeoutError

import sentry_sdk
from backend.mcp_server.tools.scrapers.cache import ScrapeCache
from backend.mcp_server.tools.scrapers.robots_gate import RobotsGate
from backend.mcp_server.tools.scrapers.sanitizer import is_bot_challenge_or_boilerplate

logger = logging.getLogger(__name__)

# Minimum character count to consider a fetch successful.
_MIN_CONTENT_LENGTH = 150


def _fetch_one(url: str, timeout: float) -> tuple[str, str]:
    """Fetch and extract a single URL with RobotsGate pacing."""
    try:
        # 1. RobotsGate protocol check and domain pacing delay
        if not RobotsGate.check_and_wait(url, timeout=min(timeout, 2.0)):
            logger.info("Trafilatura skipped URL disallowed by robots.txt: %s", url)
            return url, ""

        # Lazy import: trafilatura is an optional dependency.
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
        extracted = (text or "").strip()
        if extracted and len(extracted) >= _MIN_CONTENT_LENGTH:
            # AI_PROJECT sanity guard: Reject bot-challenge / Cloudflare interception pages
            if is_bot_challenge_or_boilerplate(extracted):
                logger.warning("Trafilatura rejected bot-challenge boilerplate from %s", url)
                return url, ""
            ScrapeCache.set(url, extracted)
        return url, extracted
    except Exception as exc:
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
                executor.submit(_fetch_one, url, timeout_per_url): url for url in urls
            }
            try:
                for future in as_completed(future_to_url, timeout=timeout_per_url + 1):
                    try:
                        url, content = future.result(timeout=timeout_per_url)
                        if content and len(content) >= _MIN_CONTENT_LENGTH:
                            results[url] = content
                    except FuturesTimeoutError:
                        logger.warning(
                            "Trafilatura timed out for %s", future_to_url.get(future)
                        )
                    except Exception as exc:
                        sentry_sdk.capture_exception(exc)
                        logger.warning("Trafilatura fetch_batch error: %s", exc)
            except FuturesTimeoutError:
                logger.warning("Trafilatura batch fetch timed out")

        return results
