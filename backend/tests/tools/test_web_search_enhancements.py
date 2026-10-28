"""
Unit tests for Veraxi Web Search enhancements (RobotsGate, QueryOptimizer, ScrapeCache, WikipediaProvider).
"""

import json
import time
from unittest.mock import MagicMock, patch

from backend.mcp_server.tools.query_optimizer import (
    optimize_search_query,
    sanitize_query,
)
from backend.mcp_server.tools.scrapers.cache import ScrapeCache
from backend.mcp_server.tools.scrapers.robots_gate import RobotsGate
from backend.mcp_server.tools.scrapers.sanitizer import (
    apply_authority_weights,
    is_bot_challenge_or_boilerplate,
)
from backend.mcp_server.tools.search_providers import (
    DuckDuckGoProvider,
    SearXNGProvider,
    WikipediaProvider,
)
from backend.mcp_server.tools.web_search import _enrich


def test_sanitize_query():
    assert sanitize_query("hello\nworld\t***") == "hello world"
    assert sanitize_query("") == ""


def test_optimize_search_query():
    # Conversational prefixes and suffixes should be cleanly stripped
    assert (
        optimize_search_query(
            "Please find recent developments in quantum computing in json"
        )
        == "recent developments in quantum computing"
    )
    # Concise queries remain intact
    assert optimize_search_query("Nvidia RTX 5090") == "Nvidia RTX 5090"


def test_scrape_cache_ttl():
    ScrapeCache.clear()
    ScrapeCache.set("https://example.com/item1", "test content", ttl=0.1)
    assert ScrapeCache.get("https://example.com/item1") == "test content"

    time.sleep(0.15)
    assert ScrapeCache.get("https://example.com/item1") is None


def test_robots_gate_disallow():
    fake_robots = (
        "User-agent: *\nDisallow: /admin/\nDisallow: /private/\nCrawl-delay: 1.0\n"
    )
    mock_resp = MagicMock()
    mock_resp.status = 200
    mock_resp.read.return_value = fake_robots.encode("utf-8")

    with patch("urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value.__enter__.return_value = mock_resp

        rules = RobotsGate.get_rules("https://testdomain.com")
        assert "/admin/" in rules["disallowed"]
        assert "/private/" in rules["disallowed"]
        assert rules["delay"] == 1.0

        # Disallowed path should be blocked
        allowed = RobotsGate.check_and_wait("https://testdomain.com/admin/secrets")
        assert allowed is False

        # Allowed path should proceed
        allowed_ok = RobotsGate.check_and_wait("https://testdomain.com/public/page")
        assert allowed_ok is True


def test_wikipedia_provider():
    provider = WikipediaProvider()

    mock_opensearch = json.dumps(
        [
            "Python",
            ["Python (programming language)"],
            [""],
            ["https://en.wikipedia.org/wiki/Python_(programming_language)"],
        ]
    ).encode("utf-8")

    mock_summary = json.dumps(
        {
            "title": "Python (programming language)",
            "extract": "Python is a high-level general-purpose programming language.",
        }
    ).encode("utf-8")

    mock_resp1 = MagicMock(status=200)
    mock_resp1.read.return_value = mock_opensearch

    mock_resp2 = MagicMock(status=200)
    mock_resp2.read.return_value = mock_summary

    cm1 = MagicMock()
    cm1.__enter__.return_value = mock_resp1
    cm2 = MagicMock()
    cm2.__enter__.return_value = mock_resp2

    with patch("urllib.request.urlopen", side_effect=[cm1, cm2]):
        results = provider.search(
            "Python", language="en", max_results=1, web_settings={}
        )
        assert len(results) == 1
        assert "Python" in results[0]["title"]
        assert "high-level" in results[0]["content"]


def test_searxng_no_fallback_on_failure():
    provider = SearXNGProvider()
    mock_settings = {}

    with patch("backend.config.get_config") as mock_cfg:
        cfg = MagicMock()
        cfg.searxng_url = "http://bad-searxng.test/search"
        mock_cfg.return_value = cfg

        # SearXNG fails, should respect user setting and return empty results without fallback
        with (
            patch("urllib.request.urlopen", side_effect=Exception("SearXNG down")),
            patch.object(DuckDuckGoProvider, "search") as mock_ddg,
        ):
            res = provider.search("test", "en", 1, mock_settings)
            assert res == []
            mock_ddg.assert_not_called()


def test_enrich_with_cache_deduplication():
    ScrapeCache.clear()
    cached_url = "https://cached-site.com/article"
    ScrapeCache.set(cached_url, "Pre-cached full article text " * 10)

    results = [{"title": "Cached", "url": cached_url, "content": "old snippet"}]

    mock_scraper = MagicMock()
    # Scraper should NOT be called because URL is already cached!
    with patch(
        "backend.mcp_server.tools.web_search.build_scraper", return_value=mock_scraper
    ):
        enriched = _enrich(results, {"scraper": "Trafilatura"})
        assert "Pre-cached full article text" in enriched[0]["content"]
        mock_scraper.fetch_batch.assert_not_called()


def test_bot_challenge_detection():
    assert (
        is_bot_challenge_or_boilerplate(
            "Just a moment... Enable JavaScript and cookies to continue"
        )
        is True
    )
    assert (
        is_bot_challenge_or_boilerplate(
            "Attention Required! | Cloudflare Ray ID: 84729482"
        )
        is True
    )
    assert (
        is_bot_challenge_or_boilerplate(
            "Unfortunately, bots use DuckDuckGo too... Select all squares containing a duck"
        )
        is True
    )
    assert (
        is_bot_challenge_or_boilerplate(
            "This is a legitimate technical article discussing GraphRAG and Neo4j architectures."
        )
        is False
    )


def test_authority_weighting():
    raw_results = [
        {
            "title": "Random Blog",
            "url": "https://random-dev-blog.net/post",
            "score": 1.0,
        },
        {
            "title": "ArXiv Paper",
            "url": "https://arxiv.org/abs/2501.00309",
            "score": 1.0,
        },
        {
            "title": "Reuters Article",
            "url": "https://reuters.com/technology/article",
            "score": 1.0,
        },
    ]
    ranked = apply_authority_weights(raw_results)
    # ArXiv paper (3.0x) should rank 1st, Reuters (1.5x) 2nd, Random blog 3rd
    assert ranked[0]["url"] == "https://arxiv.org/abs/2501.00309"
    assert ranked[0]["authority"] == "high"
    assert ranked[1]["url"] == "https://reuters.com/technology/article"
    assert ranked[1]["authority"] == "verified"
    assert ranked[2]["url"] == "https://random-dev-blog.net/post"
