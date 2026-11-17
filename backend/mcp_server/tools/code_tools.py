"""Repo X-Ray MCP tools: code_symbol, code_impact, code_overview.

Thin wrappers over :mod:`backend.retrieval.code_queries`. Each returns
a structured JSON-able dict. The graph client is injectable (``client``
keyword) so tests can run against an in-memory fake; by default the
Neo4j-backed adapter is constructed lazily per call, exactly like the
other tools in this package construct their storage clients per call.
"""

import logging
from typing import Any

import sentry_sdk

logger = logging.getLogger(__name__)

TOOL_DEFS: list[dict] = [
    {
        "name": "code_symbol",
        "description": (
            "Look up a code symbol (class, function, module or file) in the "
            "Repo X-Ray code graph by exact qualified name, falling back to "
            "exact simple name."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Qualified name (e.g. 'pkg.mod.Class.method') or simple name.",
                }
            },
            "required": ["name"],
        },
    },
    {
        "name": "code_impact",
        "description": (
            "Impact analysis: find everything that CALLS or IMPORTS a code "
            "symbol, transitively, in the Repo X-Ray code graph."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "symbol": {
                    "type": "string",
                    "description": "Qualified or simple name of the symbol.",
                },
                "max_depth": {
                    "type": "integer",
                    "description": "Maximum reverse-dependency depth (default 3).",
                },
            },
            "required": ["symbol"],
        },
    },
    {
        "name": "code_overview",
        "description": (
            "Repo X-Ray overview: code node/edge counts and the most "
            "connected symbols for the tenant, optionally under a path prefix."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "path_prefix": {
                    "type": "string",
                    "description": "Optional repo-relative path prefix to scope counts to.",
                }
            },
        },
    },
]


def tool_schemas() -> list[dict]:
    """OpenAI-style function schemas for the Repo X-Ray tools."""
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


def code_symbol(
    name: str, tenant_id: str = "default", client: Any = None
) -> dict[str, Any]:
    """Exact symbol lookup in the code graph (qualified name first)."""
    from backend.retrieval.code_queries import symbol_lookup

    try:
        return symbol_lookup(name, tenant_id=tenant_id, client=client)
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("code_symbol failed for %s: %s", name, e)
        return {"query": name, "match_type": None, "matches": [], "error": str(e)}


def code_impact(
    symbol: str,
    tenant_id: str = "default",
    max_depth: int = 3,
    client: Any = None,
) -> dict[str, Any]:
    """Transitive reverse-dependency (CALLS/IMPORTS) impact of a symbol."""
    from backend.retrieval.code_queries import impact_analysis

    try:
        return impact_analysis(
            symbol, tenant_id=tenant_id, max_depth=max_depth, client=client
        )
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("code_impact failed for %s: %s", symbol, e)
        return {
            "symbol": symbol,
            "found": False,
            "roots": [],
            "max_depth": max_depth,
            "impacted": [],
            "error": str(e),
        }


def code_overview(
    tenant_id: str = "default",
    path_prefix: str | None = None,
    client: Any = None,
) -> dict[str, Any]:
    """Code-graph counts and top connected symbols for the tenant."""
    from backend.retrieval.code_queries import repo_overview

    try:
        return repo_overview(tenant_id=tenant_id, path_prefix=path_prefix, client=client)
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("code_overview failed: %s", e)
        return {
            "tenant_id": tenant_id,
            "path_prefix": path_prefix,
            "node_counts": {},
            "edge_counts": {},
            "total_nodes": 0,
            "total_edges": 0,
            "top_connected": [],
            "error": str(e),
        }
