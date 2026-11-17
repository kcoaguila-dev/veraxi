"""Corpus Briefing MCP tool: corpus_briefing.

Thin wrapper over :mod:`backend.retrieval.corpus_briefing`, following
``code_tools.py``. The briefing is fully deterministic (no LLM); the
graph client is injectable (``client`` keyword) so tests can run
against an in-memory fake. When ``include_markdown`` is set, the
returned dict also carries a ``markdown`` rendering.
"""

import logging
from typing import Any

import sentry_sdk

logger = logging.getLogger(__name__)

TOOL_DEFS: list[dict] = [
    {
        "name": "corpus_briefing",
        "description": (
            "Deterministic corpus briefing for the tenant's knowledge "
            "graph: corpus counts, top communities (reusing graph "
            "analytics community detection) with their top entities by "
            "degree, newest entities, and heuristic contradiction "
            "flags. No LLM is used. Set include_markdown to also get "
            "a markdown rendering."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "include_markdown": {
                    "type": "boolean",
                    "description": "Also include a markdown rendering of the briefing.",
                }
            },
        },
    },
]


def tool_schemas() -> list[dict]:
    """OpenAI-style function schemas for the Corpus Briefing tools."""
    return [
        {
            "type": "function",
            "function": {
                "name": d["name"],
                "description": d["description"],
                "parameters": d["parameters"],
            },
        }
        for d in TOOL_DEFS
    ]


def corpus_briefing(
    tenant_id: str = "default",
    include_markdown: bool = False,
    client: Any = None,
) -> dict[str, Any]:
    """Build the deterministic corpus briefing for ``tenant_id``."""
    from backend.retrieval.corpus_briefing import (
        build_briefing,
        render_briefing_markdown,
    )

    try:
        briefing = build_briefing(tenant_id, client=client)
        if include_markdown:
            briefing["markdown"] = render_briefing_markdown(briefing)
        return briefing
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("corpus_briefing failed: %s", e)
        return {
            "tenant": tenant_id,
            "generated_from": {
                "total_nodes": 0,
                "total_relationships": 0,
                "nodes_by_label": {},
                "relationships_by_type": {},
                "community_count": 0,
            },
            "top_communities": [],
            "newest_entities": [],
            "contradiction_flags": [],
            "error": str(e),
        }
