"""
RobotsGate: Ethical crawling protocol gate and domain pacing manager.

Adopted and adapted from AI_PROJECT's RobotsGate substrate.
Prevents IP blacklisting and rate-limit penalties by:
  1. Inspecting target /robots.txt for Disallow rules (protecting against honeypots).
  2. Parsing and strictly respecting 'crawl-delay' directives per domain.
  3. Enforcing minimum domain-level pacing delays across concurrent threads.
  4. Caching domain policies with TTL to avoid spamming /robots.txt endpoints.
"""

from __future__ import annotations

import logging
import threading
import time
import urllib.parse
import urllib.request
from typing import Any, ClassVar

from backend.mcp_server.tools.scrapers.headers import get_browser_headers

logger = logging.getLogger(__name__)

# Cache TTL for domain robots.txt rules (1 hour)
_RULES_TTL_SECONDS = 3600.0
# Default minimum pacing between requests to the same domain (seconds)
_DEFAULT_PACING_SECONDS = 0.5
# Maximum delay we will ever sleep for to avoid hanging workers
_MAX_SLEEP_SECONDS = 3.0


class RobotsGate:
    """
    Enforces ethical scraping boundaries and request pacing per domain.
    Thread-safe and designed for concurrent scraping pools.
    """

    _lock = threading.Lock()
    _rules_cache: ClassVar[dict[str, dict[str, Any]]] = {}
    _domain_last_request: ClassVar[dict[str, float]] = {}

    @classmethod
    def get_rules(cls, domain: str, timeout: float = 3.0) -> dict[str, Any]:
        """
        Retrieves robots.txt rules for the given domain (scheme + netloc).
        Results are cached in memory for _RULES_TTL_SECONDS.
        """
        now = time.time()
        with cls._lock:
            cached = cls._rules_cache.get(domain)
            if cached and (now - cached.get("timestamp", 0)) < _RULES_TTL_SECONDS:
                return cached

        rules: dict[str, Any] = {
            "disallowed": [],
            "delay": _DEFAULT_PACING_SECONDS,
            "timestamp": now,
        }

        robots_url = urllib.parse.urljoin(domain, "/robots.txt")
        try:
            req = urllib.request.Request(
                robots_url,
                headers=get_browser_headers({"Accept": "text/plain"}),
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status == 200:
                    text = resp.read().decode("utf-8", errors="replace")
                    user_agent_active = False

                    for raw_line in text.splitlines():
                        line = raw_line.strip().lower()
                        if not line or line.startswith("#"):
                            continue

                        if line.startswith("user-agent:"):
                            agent = line.split(":", 1)[1].strip()
                            # Match wildcard or generic crawler
                            user_agent_active = agent in (
                                "*",
                                "veraxi",
                                "bot",
                                "crawler",
                            )
                        elif user_agent_active:
                            if line.startswith("disallow:"):
                                path = raw_line.split(":", 1)[1].strip()
                                if path:
                                    rules["disallowed"].append(path)
                            elif line.startswith("crawl-delay:"):
                                try:
                                    val = float(raw_line.split(":", 1)[1].strip())
                                    # Bound delay to safe maximum
                                    rules["delay"] = min(
                                        max(val, _DEFAULT_PACING_SECONDS),
                                        _MAX_SLEEP_SECONDS,
                                    )
                                except (ValueError, IndexError):
                                    pass
        except Exception as exc:
            # If robots.txt fails or 404s, allow scraping with default pacing
            logger.debug("Domain %s robots.txt lookup skipped: %s", domain, exc)

        with cls._lock:
            cls._rules_cache[domain] = rules

        return rules

    @classmethod
    def check_and_wait(cls, url: str, timeout: float = 3.0) -> bool:
        """
        Checks whether a URL is allowed under robots.txt and paces execution.

        Returns:
            True if allowed and paced.
            False if the path is explicitly Disallowed by robots.txt.
        """
        try:
            parsed = urllib.parse.urlparse(url)
            if not parsed.scheme or not parsed.netloc:
                return True

            domain = f"{parsed.scheme}://{parsed.netloc}"
            rules = cls.get_rules(domain, timeout=timeout)

            path = parsed.path or "/"
            for disallow in rules.get("disallowed", []):
                if disallow and path.startswith(disallow):
                    logger.warning(
                        "RobotsGate blocked path by robots.txt: %s (pattern: %s)",
                        path,
                        disallow,
                    )
                    return False

            delay = rules.get("delay", _DEFAULT_PACING_SECONDS)

            # Domain-level pacing
            sleep_needed = 0.0
            with cls._lock:
                now = time.time()
                last_hit = cls._domain_last_request.get(domain, 0.0)
                elapsed = now - last_hit
                if elapsed < delay:
                    sleep_needed = min(delay - elapsed, _MAX_SLEEP_SECONDS)
                # Commit next slot
                cls._domain_last_request[domain] = now + sleep_needed

            if sleep_needed > 0.01:
                logger.debug("RobotsGate pacing %s for %.2fs", domain, sleep_needed)
                time.sleep(sleep_needed)

            return True
        except Exception as exc:
            logger.debug("RobotsGate check_and_wait error for %s: %s", url, exc)
            return True
