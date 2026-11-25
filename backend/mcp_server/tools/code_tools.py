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
                },
                "repo": {
                    "type": "string",
                    "description": "Optional repo key (owner/repo or root path). Defaults to the active workspace repository.",
                },
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
                "repo": {
                    "type": "string",
                    "description": "Optional repo key (owner/repo or root path). Defaults to the active workspace repository.",
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
                },
                "repo": {
                    "type": "string",
                    "description": "Optional repo key (owner/repo or root path). Defaults to the active workspace repository.",
                },
            },
        },
    },
]

FILE_TOOL_DEFS: list[dict] = [
    {
        "name": "code_list_files",
        "description": (
            "List files and directories in the active repository (includes "
            "README.md, docs, configs, and source files). Use `pattern` to "
            "search by filename or glob."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Optional directory path relative to repo root (default '' for root).",
                },
                "pattern": {
                    "type": "string",
                    "description": "Optional filename substring or glob pattern (e.g. '*readme*', '*.py').",
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum entries to return (default 80, max 200).",
                },
                "repo": {
                    "type": "string",
                    "description": "Optional repo key. Defaults to the active workspace repository.",
                },
            },
        },
    },
    {
        "name": "code_read_file",
        "description": (
            "Read a UTF-8 text file from the active repository (such as "
            "README.md, AGENTS.md, configs, or source files) with 1-based "
            "line numbers and a citable file:// URL."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Repo-relative path to the file (e.g. 'README.md', 'backend/config.py').",
                },
                "start_line": {
                    "type": "integer",
                    "description": "Optional 1-based start line.",
                },
                "end_line": {
                    "type": "integer",
                    "description": "Optional 1-based inclusive end line.",
                },
                "repo": {
                    "type": "string",
                    "description": "Optional repo key. Defaults to the active workspace repository.",
                },
            },
            "required": ["path"],
        },
    },
]


def _to_openai_schemas(defs: list[dict]) -> list[dict]:
    return [
        {
            "type": "function",
            "function": {
                "name": d["name"],
                "description": d["description"],
                "parameters": d["parameters"],
            },
        }
        for d in defs
    ]


def tool_schemas() -> list[dict]:
    """OpenAI-style function schemas for the Repo X-Ray graph tools."""
    return _to_openai_schemas(TOOL_DEFS)


def repo_file_tool_schemas() -> list[dict]:
    """OpenAI-style function schemas for the Repo X-Ray file/tree tools."""
    return _to_openai_schemas(FILE_TOOL_DEFS)


def code_symbol(
    name: str,
    tenant_id: str = "default",
    client: Any = None,
    repo: str | None = None,
) -> dict[str, Any]:
    """Exact symbol lookup in the code graph (qualified name first)."""
    from backend.retrieval.code_queries import symbol_lookup

    try:
        return symbol_lookup(name, tenant_id=tenant_id, client=client, repo=repo)
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("code_symbol failed for %s: %s", name, e)
        return {"query": name, "match_type": None, "matches": [], "error": str(e)}


def code_impact(
    symbol: str,
    tenant_id: str = "default",
    max_depth: int = 3,
    client: Any = None,
    repo: str | None = None,
) -> dict[str, Any]:
    """Transitive reverse-dependency (CALLS/IMPORTS) impact of a symbol."""
    from backend.retrieval.code_queries import impact_analysis

    try:
        return impact_analysis(
            symbol, tenant_id=tenant_id, max_depth=max_depth, client=client, repo=repo
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
    repo: str | None = None,
) -> dict[str, Any]:
    """Code-graph counts and top connected symbols for the tenant."""
    from backend.retrieval.code_queries import repo_overview

    try:
        return repo_overview(
            tenant_id=tenant_id, path_prefix=path_prefix, client=client, repo=repo
        )
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


async def code_list_files(
    path: str = "",
    *,
    pattern: str | None = None,
    limit: int = 80,
    tenant_id: str = "default",
    repo: str | None = None,
) -> dict[str, Any]:
    """List files/directories in a tenant-accessible repository."""
    from backend.services.repo_files import RepoFileError, list_repo_entries

    if not repo:
        return {"path": path, "entries": [], "error": "No active repository specified."}
    try:
        return await list_repo_entries(
            tenant_id, repo, path=path, pattern=pattern, limit=limit
        )
    except RepoFileError as exc:
        return {"repo_key": repo, "path": path, "entries": [], "error": exc.detail}
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.error("code_list_files failed for %s: %s", repo, exc)
        return {"repo_key": repo, "path": path, "entries": [], "error": str(exc)}


async def code_read_file(
    path: str,
    *,
    start_line: int | None = None,
    end_line: int | None = None,
    max_chars: int | None = None,
    tenant_id: str = "default",
    repo: str | None = None,
) -> dict[str, Any]:
    """Read a UTF-8 text file from a tenant-accessible repository."""
    from backend.services.repo_files import (
        DEFAULT_READ_MAX_CHARS,
        RepoFileError,
        read_repo_file,
    )

    if not repo:
        return {"path": path, "error": "No active repository specified."}
    try:
        return await read_repo_file(
            tenant_id,
            repo,
            path,
            start_line=start_line,
            end_line=end_line,
            max_chars=max_chars if max_chars is not None else DEFAULT_READ_MAX_CHARS,
        )
    except RepoFileError as exc:
        return {"repo_key": repo, "path": path, "error": exc.detail}
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.error("code_read_file failed for %s/%s: %s", repo, path, exc)
        return {"repo_key": repo, "path": path, "error": str(exc)}
