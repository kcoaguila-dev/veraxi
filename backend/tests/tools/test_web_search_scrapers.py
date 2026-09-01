"""
Tests for the web search scraper enrichment pipeline.

These tests use mocking so they don't make real network calls.
Run with: backend/.venv/bin/pytest backend/tests/tools/test_web_search_scrapers.py -v
"""
from __future__ import annotations

import sys
import types
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_SAMPLE_RESULTS = [
    {"title": "Yahoo Finance Article", "url": "https://finance.yahoo.com/news/a", "content": "snippet a"},
    {"title": "Reuters Article",       "url": "https://reuters.com/news/b",       "content": "snippet b"},
    {"title": "No-URL Entry",          "url": "",                                  "content": "snippet c"},
]

_LONG_TEXT = "x" * 500   # > _MIN_CONTENT_LENGTH


# ---------------------------------------------------------------------------
# build_scraper factory
# ---------------------------------------------------------------------------

class TestBuildScraper:
    def test_none_returns_none(self):
        from backend.mcp_server.tools.scrapers import build_scraper
        assert build_scraper({"scraper": "None"}) is None

    def test_empty_returns_none(self):
        from backend.mcp_server.tools.scrapers import build_scraper
        assert build_scraper({}) is None

    def test_serper_returns_none(self):
        from backend.mcp_server.tools.scrapers import build_scraper
        assert build_scraper({"scraper": "Serper Scrape API"}) is None

    def test_tavily_returns_none(self):
        from backend.mcp_server.tools.scrapers import build_scraper
        assert build_scraper({"scraper": "Tavily Extract API"}) is None

    def test_trafilatura_returns_scraper(self):
        from backend.mcp_server.tools.scrapers import build_scraper
        from backend.mcp_server.tools.scrapers.trafilatura_scraper import (
            TrafilaturaScraper,
        )
        scraper = build_scraper({"scraper": "Trafilatura"})
        assert isinstance(scraper, TrafilaturaScraper)

    def test_jina_returns_scraper(self):
        from backend.mcp_server.tools.scrapers import build_scraper
        from backend.mcp_server.tools.scrapers.jina_scraper import JinaScraper
        scraper = build_scraper({"scraper": "Jina Reader", "jina_api_key": "key123"})
        assert isinstance(scraper, JinaScraper)
        assert scraper._api_key == "key123"

    def test_firecrawl_returns_scraper(self):
        from backend.mcp_server.tools.scrapers import build_scraper
        from backend.mcp_server.tools.scrapers.firecrawl_scraper import FirecrawlScraper
        scraper = build_scraper({
            "scraper": "Firecrawl API",
            "firecrawl_url": "https://my.firecrawl.local",
            "firecrawl_api_key": "fc-secret",
        })
        assert isinstance(scraper, FirecrawlScraper)
        assert scraper._base_url == "https://my.firecrawl.local"
        assert scraper._api_key == "fc-secret"


# ---------------------------------------------------------------------------
# _enrich helper
# ---------------------------------------------------------------------------

class TestEnrich:
    def _enrich(self, results, web_settings):
        from backend.mcp_server.tools.web_search import _enrich
        return _enrich(results, web_settings)

    def test_no_scraper_returns_results_unchanged(self):
        results = [r.copy() for r in _SAMPLE_RESULTS]
        out = self._enrich(results, {"scraper": "None"})
        assert out[0]["content"] == "snippet a"
        assert out[1]["content"] == "snippet b"

    def test_trafilatura_enriches_content(self):
        import copy
        results = copy.deepcopy(_SAMPLE_RESULTS)
        mock_scraper = MagicMock()
        mock_scraper.fetch_batch.return_value = {
            "https://finance.yahoo.com/news/a": _LONG_TEXT,
            "https://reuters.com/news/b": _LONG_TEXT + "extra",
        }
        with patch(
            "backend.mcp_server.tools.web_search.build_scraper",
            return_value=mock_scraper,
        ):
            out = self._enrich(results, {"scraper": "Trafilatura"})

        assert out[0]["content"] == _LONG_TEXT
        assert out[1]["content"] == _LONG_TEXT + "extra"
        # URL-less entry untouched
        assert out[2]["content"] == "snippet c"

    def test_scraper_timeout_falls_back_to_snippet(self):
        import copy
        results = copy.deepcopy(_SAMPLE_RESULTS)
        mock_scraper = MagicMock()
        # Scraper returns nothing — network timeout scenario
        mock_scraper.fetch_batch.return_value = {}
        with patch(
            "backend.mcp_server.tools.web_search.build_scraper",
            return_value=mock_scraper,
        ):
            out = self._enrich(results, {"scraper": "Trafilatura"})

        assert out[0]["content"] == "snippet a"
        assert out[1]["content"] == "snippet b"

    def test_scraper_exception_falls_back_gracefully(self):
        import copy
        results = copy.deepcopy(_SAMPLE_RESULTS)
        mock_scraper = MagicMock()
        mock_scraper.fetch_batch.side_effect = RuntimeError("network dead")
        with patch(
            "backend.mcp_server.tools.web_search.build_scraper",
            return_value=mock_scraper,
        ):
            out = self._enrich(results, {"scraper": "Trafilatura"})

        # Must not raise; original snippets preserved
        assert out[0]["content"] == "snippet a"

    def test_content_truncated_to_4000_chars(self):
        import copy
        results = copy.deepcopy(_SAMPLE_RESULTS[:1])
        huge_text = "y" * 10_000
        mock_scraper = MagicMock()
        mock_scraper.fetch_batch.return_value = {
            "https://finance.yahoo.com/news/a": huge_text,
        }
        with patch(
            "backend.mcp_server.tools.web_search.build_scraper",
            return_value=mock_scraper,
        ):
            out = self._enrich(results, {"scraper": "Jina Reader"})

        assert len(out[0]["content"]) == 4000

    def test_respects_scraper_max_pages_setting(self):
        import copy
        results = copy.deepcopy(_SAMPLE_RESULTS)
        mock_scraper = MagicMock()
        mock_scraper.fetch_batch.return_value = {}

        with patch(
            "backend.mcp_server.tools.web_search.build_scraper",
            return_value=mock_scraper,
        ):
            self._enrich(results, {"scraper": "Trafilatura", "scraper_max_pages": 1})

        # Only 1 URL should have been passed to fetch_batch
        called_urls = mock_scraper.fetch_batch.call_args[0][0]
        assert len(called_urls) == 1


# ---------------------------------------------------------------------------
# Trafilatura scraper unit
# ---------------------------------------------------------------------------

class TestTrafilaturaScraper:
    def test_returns_extracted_content(self):
        # Mock the trafilatura module itself so it doesn't need to be installed
        fake_trafilatura = types.ModuleType("trafilatura")
        fake_trafilatura.fetch_url = MagicMock(return_value="<html>body</html>")
        fake_trafilatura.extract = MagicMock(return_value=_LONG_TEXT)

        with patch.dict(sys.modules, {"trafilatura": fake_trafilatura}):
            from backend.mcp_server.tools.scrapers.trafilatura_scraper import (
                TrafilaturaScraper,
            )
            scraper = TrafilaturaScraper()
            result = scraper.fetch_batch(["https://example.com"], timeout_per_url=5.0)

        assert "https://example.com" in result
        assert result["https://example.com"] == _LONG_TEXT

    def test_short_content_excluded(self):
        fake_trafilatura = types.ModuleType("trafilatura")
        fake_trafilatura.fetch_url = MagicMock(return_value="<html/>")
        fake_trafilatura.extract = MagicMock(return_value="too short")

        with patch.dict(sys.modules, {"trafilatura": fake_trafilatura}):
            from backend.mcp_server.tools.scrapers.trafilatura_scraper import (
                TrafilaturaScraper,
            )
            scraper = TrafilaturaScraper()
            result = scraper.fetch_batch(["https://example.com"])

        assert result == {}

    def test_empty_url_list_returns_empty(self):
        from backend.mcp_server.tools.scrapers.trafilatura_scraper import (
            TrafilaturaScraper,
        )
        assert TrafilaturaScraper().fetch_batch([]) == {}
