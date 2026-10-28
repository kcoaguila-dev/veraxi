"""
Realistic browser headers and fingerprinting helpers for Veraxi scrapers and search providers.

Prevents anti-bot systems (Cloudflare, Akamai, CloudFront, ModSecurity) from immediately
flagging and banning scraping agents using identifiable generic bot strings.
"""

from __future__ import annotations

import random

# Modern desktop Chrome and Safari user-agents
USER_AGENTS = [
    (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    ),
    (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    ),
    (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    ),
]

DEFAULT_BROWSER_HEADERS: dict[str, str] = {
    "User-Agent": USER_AGENTS[0],
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "DNT": "1",
    "Sec-Ch-Ua": '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
    "Sec-Ch-Ua-Mobile": "?0",
    "Sec-Ch-Ua-Platform": '"Windows"',
    "Upgrade-Insecure-Requests": "1",
}


def get_browser_headers(extra: dict[str, str] | None = None) -> dict[str, str]:
    """Returns standard browser headers with optional overrides."""
    headers = dict(DEFAULT_BROWSER_HEADERS)
    headers["User-Agent"] = random.choice(USER_AGENTS)
    if extra:
        headers.update(extra)
    return headers
