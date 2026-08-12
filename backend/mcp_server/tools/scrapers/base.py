"""
Base protocol and result type for all page-content scrapers.

Each scraper must implement fetch_batch(), which accepts a list of URLs and a
per-URL timeout, and returns a dict mapping URL → extracted plain text.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable


@dataclass
class ScraperResult:
    """Holds the outcome of a single page fetch attempt."""
    url: str
    content: str
    error: str | None = field(default=None)

    @property
    def ok(self) -> bool:
        """True when content was successfully extracted."""
        return bool(self.content) and self.error is None


@runtime_checkable
class PageScraper(Protocol):
    """
    Strategy interface for page-content extraction.

    Implementations must be stateless and safe to call from multiple threads.
    """

    def fetch_batch(
        self,
        urls: list[str],
        timeout_per_url: float = 5.0,
    ) -> dict[str, str]:
        """
        Fetch and extract text content for each URL.

        Args:
            urls: List of URLs to fetch (already deduped by caller).
            timeout_per_url: Maximum seconds to spend on a single URL.

        Returns:
            Mapping of url → extracted plain text.
            URLs that fail are omitted from the result.
        """
        ...
