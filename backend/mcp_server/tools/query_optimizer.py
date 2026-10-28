"""
Query optimizer and sanitizer for Veraxi Web Search.

Inspired by AI_PROJECT's query optimization substrate.
Transforms conversational and noisy user prompts into concise, high-relevance search keywords
to improve engine retrieval veracity and avoid search-engine bot/spam rate limits.
"""

from __future__ import annotations

import logging
import re

logger = logging.getLogger(__name__)

# Common conversational fluff patterns at the start or end of queries
_FLUFF_PREFIXES = [
    r"^(?:please\s+)?(?:can\s+you\s+)?(?:find|search(?:\s+for)?|list|show(?:\s+me)?|get|look\s+up|tell\s+me\s+about|what\s+is|what\s+are|how\s+to|how\s+do\s+i|explain)\s+(?:a\s+|an\s+|the\s+)?",
    r"^(?:give\s+me|fetch|retrieve|gather)\s+(?:information\s+on|details\s+about|data\s+on)?\s*",
]

_FLUFF_SUFFIXES = [
    r"\s+(?:for\s+me|please|thanks)$",
    r"\s+in\s+(?:csv|tsv|json|excel|table|markdown|bullet\s+points)$",
    r"\s+as\s+a\s+(?:csv|tsv|json|excel|table|markdown|summary)$",
]


def sanitize_query(query: str, max_length: int = 200) -> str:
    """
    Cleans raw query strings by stripping newlines, control characters,
    excessive markdown, and boundary whitespace.
    """
    if not query:
        return ""

    # Force string and strip markdown syntax
    clean = str(query)
    clean = re.sub(r"[*#>`~_\[\]]", " ", clean)

    # Normalize whitespace (replace newlines/tabs with single space)
    clean = re.sub(r"\s+", " ", clean)

    # Keep only printable characters
    clean = "".join(char for char in clean if char.isprintable())

    return clean.strip()[:max_length]


def optimize_search_query(query: str) -> str:
    """
    Transforms conversational prompts into concise search terms.

    Example:
        'Please find recent news about Nvidia Blackwell GPUs in table format'
        -> 'Nvidia Blackwell GPUs recent news'
    """
    sanitized = sanitize_query(query)
    if not sanitized:
        return ""

    tokens = sanitized.split()
    # If already a concise 1-3 word query without fluff, return directly
    if len(tokens) <= 3 and not any(
        w in sanitized.lower()
        for w in ["find", "search", "list", "show", "get", "what", "how", "who"]
    ):
        return sanitized

    optimized = sanitized
    # Strip conversational prefixes
    for pat in _FLUFF_PREFIXES:
        optimized = re.sub(pat, "", optimized, flags=re.IGNORECASE).strip()

    # Strip conversational suffixes
    for pat in _FLUFF_SUFFIXES:
        optimized = re.sub(pat, "", optimized, flags=re.IGNORECASE).strip()

    # Remove extra quotes
    optimized = optimized.strip("\"'").strip()

    # If heuristic stripped everything, fallback to sanitized query
    if not optimized or len(optimized) < 2:
        return sanitized

    logger.debug("Optimized query: '%s' -> '%s'", sanitized, optimized)
    return optimized
