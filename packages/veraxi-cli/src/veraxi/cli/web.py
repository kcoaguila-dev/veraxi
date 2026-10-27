"""Veraxi Web Engine for Termux & Headless CLI Agents.

Provides multi-provider web search (DuckDuckGo, SearXNG, Serper, Tavily)
and clean markdown page extraction (via Jina Reader).
Designed for mobile (Termux) and desktop agentic workflows.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from veraxi.cli.config import load_cli_config, set_config_value

SUPPORTED_PROVIDERS = {
    "duckduckgo": {
        "label": "DuckDuckGo",
        "description": "Zero-key public HTML search (default, zero configuration)",
        "requires_key": False,
    },
    "searxng": {
        "label": "SearXNG",
        "description": "Self-hosted private meta-search engine (Docker / localhost:8080)",
        "requires_key": False,
        "config_key": "searxng_url",
        "env_var": "SEARXNG_URL",
        "default_url": "http://localhost:8080",
    },
    "serper": {
        "label": "Serper (Google)",
        "description": "High-speed Google Search API for structured web snippets",
        "requires_key": True,
        "config_key": "serper_api_key",
        "env_var": "SERPER_API_KEY",
    },
    "tavily": {
        "label": "Tavily",
        "description": "AI-native search engine optimized for LLM agent context",
        "requires_key": True,
        "config_key": "tavily_api_key",
        "env_var": "TAVILY_API_KEY",
    },
}


def _search_duckduckgo(query: str, limit: int = 5) -> list[dict[str, str]]:
    clean_query = query.strip()
    encoded = urllib.parse.quote_plus(clean_query)
    url = f"https://html.duckduckgo.com/html/?q={encoded}"

    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36"
        )
    }

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            html = resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"Error connecting to DuckDuckGo: {e}", file=sys.stderr)
        return []

    snippet_pattern = re.compile(
        r'<a class="result__snippet[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
        re.DOTALL,
    )
    generic_pattern = re.compile(
        r'class="result__snippet"[^>]*>(.*?)<\/(?:td|a|div)>',
        re.DOTALL,
    )

    results: list[dict[str, str]] = []
    matches = snippet_pattern.findall(html)
    if matches:
        for link, snippet_raw in matches[:limit]:
            clean_snippet = re.sub(r"<[^>]*>", "", snippet_raw).strip()
            clean_snippet = (
                clean_snippet.replace("&quot;", '"')
                .replace("&amp;", "&")
                .replace("&#x27;", "'")
            )
            actual_url = link
            if "uddg=" in link:
                try:
                    query_params = urllib.parse.parse_qs(urllib.parse.urlparse(link).query)
                    actual_url = query_params.get("uddg", [link])[0]
                except Exception:
                    actual_url = link

            results.append({"snippet": clean_snippet, "url": actual_url})
    else:
        generic_matches = generic_pattern.findall(html)
        for snippet_raw in generic_matches[:limit]:
            clean_snippet = re.sub(r"<[^>]*>", "", snippet_raw).strip()
            clean_snippet = (
                clean_snippet.replace("&quot;", '"')
                .replace("&amp;", "&")
                .replace("&#x27;", "'")
            )
            results.append({"snippet": clean_snippet, "url": ""})

    return results


def _search_searxng(query: str, limit: int = 5, base_url: str = "http://localhost:8080") -> list[dict[str, str]]:
    clean_url = base_url.rstrip("/")
    target = f"{clean_url}/search" if not clean_url.endswith("/search") else clean_url
    params = urllib.parse.urlencode({"q": query, "format": "json"})
    req_url = f"{target}?{params}"

    req = urllib.request.Request(req_url, headers={"User-Agent": "Veraxi-Agent/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            results = []
            for item in data.get("results", [])[:limit]:
                snippet = item.get("content") or item.get("snippet") or ""
                results.append({"snippet": snippet.strip(), "url": item.get("url", "")})
            return results
    except Exception as e:
        print(f"Error querying SearXNG ({clean_url}): {e}. Falling back to DuckDuckGo.", file=sys.stderr)
        return _search_duckduckgo(query, limit)


def _search_serper(query: str, limit: int = 5, api_key: str | None = None) -> list[dict[str, str]]:
    if not api_key:
        print("Error: Serper API key missing. Falling back to DuckDuckGo.", file=sys.stderr)
        return _search_duckduckgo(query, limit)

    req = urllib.request.Request(
        "https://google.serper.dev/search",
        data=json.dumps({"q": query, "num": limit}).encode("utf-8"),
        headers={
            "X-API-KEY": api_key,
            "Content-Type": "application/json",
            "User-Agent": "Veraxi-Agent/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            results = []
            for item in data.get("organic", [])[:limit]:
                results.append({"snippet": item.get("snippet", "").strip(), "url": item.get("link", "")})
            return results
    except Exception as e:
        print(f"Error querying Serper: {e}. Falling back to DuckDuckGo.", file=sys.stderr)
        return _search_duckduckgo(query, limit)


def _search_tavily(query: str, limit: int = 5, api_key: str | None = None) -> list[dict[str, str]]:
    if not api_key:
        print("Error: Tavily API key missing. Falling back to DuckDuckGo.", file=sys.stderr)
        return _search_duckduckgo(query, limit)

    req = urllib.request.Request(
        "https://api.tavily.com/search",
        data=json.dumps({"api_key": api_key, "query": query, "max_results": limit}).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": "Veraxi-Agent/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            results = []
            for item in data.get("results", [])[:limit]:
                results.append({"snippet": item.get("content", "").strip(), "url": item.get("url", "")})
            return results
    except Exception as e:
        print(f"Error querying Tavily: {e}. Falling back to DuckDuckGo.", file=sys.stderr)
        return _search_duckduckgo(query, limit)


def web_search(query: str, limit: int = 5, provider: str | None = None) -> list[dict[str, str]]:
    """Executes a web search with the active or requested search provider."""
    if not query or not query.strip():
        return []

    cfg = load_cli_config()
    chosen_provider = (provider or cfg.get("web_provider") or os.environ.get("VERAXI_WEB_PROVIDER") or "duckduckgo").lower().strip()

    if chosen_provider == "searxng":
        searxng_url = cfg.get("searxng_url") or os.environ.get("SEARXNG_URL") or "http://localhost:8080"
        return _search_searxng(query, limit, base_url=searxng_url)
    elif chosen_provider == "serper":
        serper_key = cfg.get("serper_api_key") or os.environ.get("SERPER_API_KEY")
        return _search_serper(query, limit, api_key=serper_key)
    elif chosen_provider == "tavily":
        tavily_key = cfg.get("tavily_api_key") or os.environ.get("TAVILY_API_KEY")
        return _search_tavily(query, limit, api_key=tavily_key)
    else:
        return _search_duckduckgo(query, limit)


def fetch_web_page(url: str, max_chars: int = 5000) -> str:
    """Fetches a webpage and extracts clean LLM-ready markdown or text."""
    if not url or not url.strip():
        return ""

    clean_url = url.strip()

    # 1. Try Jina Reader
    jina_url = f"https://r.jina.ai/{clean_url}"
    headers = {
        "Accept": "text/plain",
        "X-Return-Format": "text",
        "User-Agent": "Veraxi-Agent/1.0",
    }
    req = urllib.request.Request(jina_url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            text = resp.read().decode("utf-8", errors="replace").strip()
            if len(text) > 50:
                if len(text) > max_chars:
                    return text[:max_chars] + "\n\n... [truncated for context length]"
                return text
    except Exception:
        pass

    # 2. Fallback to direct HTTP fetch
    req_direct = urllib.request.Request(clean_url, headers={"User-Agent": "Veraxi-Agent/1.0"})
    try:
        with urllib.request.urlopen(req_direct, timeout=10) as resp:
            html = resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        return f"Error fetching {clean_url}: {e}"

    # Strip script and style
    text = re.sub(r"<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>", "", html, flags=re.I)
    text = re.sub(r"<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>", "", text, flags=re.I)
    text = re.sub(r"<[^>]*>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()

    if len(text) > max_chars:
        return text[:max_chars] + "\n\n... [truncated]"
    return text


def run_web_providers_list(as_json: bool = False):
    """Displays available web search providers and configuration status."""
    cfg = load_cli_config()
    active = (cfg.get("web_provider") or os.environ.get("VERAXI_WEB_PROVIDER") or "duckduckgo").lower().strip()

    if as_json:
        payload = {
            "active_provider": active,
            "providers": {},
        }
        for name, meta in SUPPORTED_PROVIDERS.items():
            configured = True
            if meta.get("requires_key"):
                configured = bool(cfg.get(meta["config_key"]) or os.environ.get(meta["env_var"]))
            payload["providers"][name] = {
                "label": meta["label"],
                "description": meta["description"],
                "configured": configured,
                "active": name == active,
            }
        print(json.dumps(payload, indent=2))
        return

    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    yellow = "\033[33m"
    dim = "\033[2m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi Web Search Providers Catalog                ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")
    print(f"  Active Search Provider: {bold}{green}{active}{reset}\n")

    for name, meta in SUPPORTED_PROVIDERS.items():
        is_active = name == active
        marker = f"{green}* {reset}" if is_active else "  "
        status = f"{green}[READY]{reset}"
        if meta.get("requires_key"):
            has_key = bool(cfg.get(meta["config_key"]) or os.environ.get(meta["env_var"]))
            status = f"{green}[KEY SET]{reset}" if has_key else f"{yellow}[NO KEY CONFIGURED]{reset}"
        elif name == "searxng":
            url = cfg.get("searxng_url") or os.environ.get("SEARXNG_URL") or "http://localhost:8080"
            status = f"{dim}({url}){reset}"

        print(f"{marker}{bold}{meta['label']:<15}{reset} {status}")
        print(f"    {dim}{meta['description']}{reset}")
        print()

    print(f"{dim}Tip: Switch provider with: vx web provider set <duckduckgo|searxng|serper|tavily>{reset}")
    print(f"{dim}     Configure keys with:   vx config set <serper_api_key|tavily_api_key|searxng_url> <val>{reset}\n")


def run_web_provider_set(provider_name: str | None = None):
    """Sets the active web search provider in persistent CLI config."""
    if not provider_name or provider_name.lower().strip() not in SUPPORTED_PROVIDERS:
        valid = ", ".join(SUPPORTED_PROVIDERS.keys())
        print(f"Error: Invalid provider '{provider_name}'. Supported providers: {valid}", file=sys.stderr)
        sys.exit(1)

    clean_name = provider_name.lower().strip()
    if set_config_value("web_provider", clean_name):
        bold = "\033[1m"
        green = "\033[32m"
        reset = "\033[0m"
        print(f"{green}✓ Set default web search provider to:{reset} {bold}{clean_name}{reset}")
    else:
        print("Failed to save web provider configuration.", file=sys.stderr)
        sys.exit(1)


def run_web(
    action: str,
    query_or_url: str | None = None,
    provider_name: str | None = None,
    provider: str | None = None,
    limit: int = 5,
    as_json: bool = False,
):
    """CLI handler for `vx web search`, `vx web fetch`, and `vx web provider`."""
    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    dim = "\033[2m"
    reset = "\033[0m"

    if action == "provider":
        if query_or_url == "set":
            run_web_provider_set(provider_name)
        else:
            run_web_providers_list(as_json=as_json)
        return

    if action == "search":
        if not query_or_url:
            print("Error: Search query required. Usage: vx web search <query>", file=sys.stderr)
            sys.exit(1)

        results = web_search(query_or_url, limit=limit, provider=provider)

        if as_json:
            print(json.dumps({"query": query_or_url, "results": results}, indent=2))
            return

        print(f"\n{bold}{cyan}Web Search Results for: {reset}{bold}{query_or_url}{reset}\n")
        if not results:
            print(f"{dim}No results found.{reset}")
            return

        for i, item in enumerate(results, 1):
            url_str = f" ({item['url']})" if item.get("url") else ""
            print(f"{bold}{green}[{i}]{reset}{url_str}")
            print(f"    {item['snippet']}\n")

    elif action == "fetch":
        if not query_or_url:
            print("Error: URL required. Usage: vx web fetch <url>", file=sys.stderr)
            sys.exit(1)

        content = fetch_web_page(query_or_url)

        if as_json:
            print(json.dumps({"url": query_or_url, "content": content}, indent=2))
            return

        print(f"\n{bold}{cyan}Web Page Content: {reset}{bold}{query_or_url}{reset}\n")
        print(content)
        print()
    else:
        print(f"Unknown web action: {action}. Choose 'search', 'fetch', or 'provider'.", file=sys.stderr)
        sys.exit(1)
