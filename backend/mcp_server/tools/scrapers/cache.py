"""
Lightweight scrape freshness cache for deduplication and rate-limit reduction.

Inspired by AI_PROJECT's 24-hour freshness verification.
Prevents redundant scraping of recently-fetched URLs, minimizing network overhead
and significantly reducing IP-ban risk across multi-hop GraphRAG queries.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import ClassVar

logger = logging.getLogger(__name__)

# Default 24-hour TTL for scraped article text
_DEFAULT_CACHE_TTL = 86400.0
# Maximum in-memory cached entries
_MAX_ENTRIES = 1000


class ScrapeCache:
    """Thread-safe in-memory cache with TTL for scraped page content."""

    _lock = threading.Lock()
    _store: ClassVar[dict[str, tuple[str, float]]] = {}

    @classmethod
    def get(cls, url: str) -> str | None:
        """Retrieves cached content if present and not expired."""
        if not url:
            return None
        now = time.time()
        with cls._lock:
            entry = cls._store.get(url)
            if entry:
                content, expire_at = entry
                if now < expire_at:
                    return content
                # Expired
                cls._store.pop(url, None)
        return None

    @classmethod
    def set(cls, url: str, content: str, ttl: float = _DEFAULT_CACHE_TTL) -> None:
        """Stores extracted text with TTL."""
        if not url or not content:
            return
        now = time.time()
        with cls._lock:
            # Simple eviction if max size reached
            if len(cls._store) >= _MAX_ENTRIES:
                oldest_key = min(cls._store, key=lambda k: cls._store[k][1])
                cls._store.pop(oldest_key, None)
            cls._store[url] = (content, now + ttl)

    @classmethod
    def clear(cls) -> None:
        """Clears all cached entries (primarily for testing)."""
        with cls._lock:
            cls._store.clear()
