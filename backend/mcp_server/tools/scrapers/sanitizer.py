"""
Text sanitization and bot challenge detection for scraped web pages.

Ported and enhanced from AI_PROJECT's OmniResearchAdapter to purge
Cloudflare, CAPTCHA, and CDN security challenge walls from contaminating
the RAG knowledge graph.
"""

from __future__ import annotations

# Signatures of bot-block walls, Cloudflare challenges, and CAPTCHA intercepts.
BOT_CHALLENGE_PATTERNS = [
    "just a moment",
    "verify you are a human",
    "attention required! | cloudflare",
    "access denied",
    "enable javascript",
    "security service",
    "check your browser",
    "unfortunately, bots use duckduckgo too",
    "ddg captcha",
    "ray id:",
    "cloudflare ray id",
    "please turn javascript on and reload the page",
    "completing the challenge below proves you are human",
    "pardon our interruption",
    "unusual traffic from your computer network",
]


def is_bot_challenge_or_boilerplate(text: str, scan_window: int = 1500) -> bool:
    """
    Returns True if the extracted text contains bot-challenge or access-denied boilerplate.
    
    Scans the initial character window (default: 1500 chars) where challenge banners appear.
    """
    if not text:
        return True
        
    head = text[:scan_window].lower()
    for pattern in BOT_CHALLENGE_PATTERNS:
        if pattern in head:
            return True
            
    return False


def apply_authority_weights(results: list[dict]) -> list[dict]:
    """
    Applies heritage domain authority weighting to search results.
    
    Inspired by AI_PROJECT's OmniResearch authority logic:
    - 3.0x multiplier on high-truth academic/governmental domains (.edu, .gov, arxiv, jstor, ieee)
    - 1.5x multiplier on verified journalism (reuters, bloomberg, nature, science)
    - Re-ranks results so high-veracity sources float to the top for RAG synthesis.
    """
    high_truth_domains = [
        ".edu",
        ".gov",
        "arxiv.org",
        "jstor.org",
        "ieee.org",
        "researchgate.net",
        "ncbi.nlm.nih.gov",
        "nature.com",
        "science.org",
        "semanticscholar.org",
        "crossref.org",
        "wikipedia.org",
        "github.com",
    ]
    news_domains = ["reuters.com", "bloomberg.com", "apnews.com"]

    for res in results:
        url = res.get("url", "").lower()
        score = float(res.get("score", 1.0))

        if any(d in url for d in high_truth_domains):
            res["score"] = score * 3.0
            res["authority"] = "high"
        elif any(d in url for d in news_domains):
            res["score"] = score * 1.5
            res["authority"] = "verified"
        else:
            res["score"] = score
            res["authority"] = "standard"

    # Sort descending by calculated score
    return sorted(results, key=lambda r: float(r.get("score", 0.0)), reverse=True)
