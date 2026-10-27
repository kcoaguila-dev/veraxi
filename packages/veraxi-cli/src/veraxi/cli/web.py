"""Veraxi Web Engine for Termux & Headless CLI Agents.

Provides zero-dependency web search and clean markdown page extraction (via DuckDuckGo and Jina Reader).
Designed for mobile (Termux) and desktop agentic workflows.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


def web_search(query: str, limit: int = 5) -> list[dict[str, str]]:
    """Searches the web via DuckDuckGo without external API keys or headless browsers."""
    if not query or not query.strip():
        return []

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
        print(f"Error connecting to web search: {e}", file=sys.stderr)
        return []

    # Parse DuckDuckGo search snippets and links
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
            # DuckDuckGo redirect cleaner
            actual_url = link
            if "uddg=" in link:
                try:
                    query_params = urllib.parse.parse_qs(urllib.parse.urlparse(link).query)
                    actual_url = query_params.get("uddg", [link])[0]
                except Exception:
                    actual_url = link

            results.append({
                "snippet": clean_snippet,
                "url": actual_url,
            })
    else:
        generic_matches = generic_pattern.findall(html)
        for snippet_raw in generic_matches[:limit]:
            clean_snippet = re.sub(r"<[^>]*>", "", snippet_raw).strip()
            clean_snippet = (
                clean_snippet.replace("&quot;", '"')
                .replace("&amp;", "&")
                .replace("&#x27;", "'")
            )
            results.append({
                "snippet": clean_snippet,
                "url": "",
            })

    return results


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


def run_web(
    action: str,
    query_or_url: str | None = None,
    limit: int = 5,
    as_json: bool = False,
):
    """CLI handler for `vx web search` and `vx web fetch`."""
    cyan = "\033[36m"
    bold = "\033[1m"
    green = "\033[32m"
    dim = "\033[2m"
    reset = "\033[0m"

    if action == "search":
        if not query_or_url:
            print("Error: Search query required. Usage: vx web search <query>", file=sys.stderr)
            sys.exit(1)

        results = web_search(query_or_url, limit=limit)

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
        print(f"Unknown web action: {action}. Choose 'search' or 'fetch'.", file=sys.stderr)
        sys.exit(1)
