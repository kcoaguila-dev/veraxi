"""Data pack MCP tool: dataset_discovery.

Thin wrapper over :mod:`backend.retrieval.dbt_queries`, following
``code_tools.py``. The graph client is injectable (``client``
keyword) so tests can run against an in-memory fake.
"""

import logging
from typing import Any

import sentry_sdk

logger = logging.getLogger(__name__)

TOOL_DEFS: list[dict] = [
    {
        "name": "dataset_discovery",
        "description": (
            "Discover dbt datasets/models by dataset-name fragment or "
            "exact column name, with one-hop upstream/downstream "
            "lineage for each match (from the dbt lineage graph)."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Column name (exact) or dataset/model name fragment (contains).",
                }
            },
            "required": ["query"],
        },
    },
]


def tool_schemas() -> list[dict]:
    """OpenAI-style function schemas for the data-pack tools."""
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


def dataset_discovery(
    query: str, tenant_id: str = "default", client: Any = None
) -> dict[str, Any]:
    """Find datasets/models by column name or name fragment."""
    from backend.retrieval.dbt_queries import (
        dataset_discovery as _dataset_discovery,
    )

    try:
        return _dataset_discovery(query, tenant_id=tenant_id, client=client)
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("dataset_discovery failed for %s: %s", query, e)
        return {"query": query, "matches": [], "error": str(e)}
