"""Vuln Intel MCP tool: vuln_report.

Thin wrapper over :mod:`backend.retrieval.vuln_queries`, following
``code_tools.py``. The caller supplies either an explicit list of
extracted dependencies or a ``repo_path`` to extract them from (via
:mod:`backend.ingestion.dependencies` — the tools layer may call both
retrieval and ingestion helpers). Each finding reports the package,
its installed/base version, the CVE id, severity, CWE ids, whether
the CVE is in CISA KEV, and a conservative ``match_status`` of
``matched`` or ``unknown`` (never a guessed match).
"""

import logging
from typing import Any

import sentry_sdk

logger = logging.getLogger(__name__)

TOOL_DEFS: list[dict] = [
    {
        "name": "vuln_report",
        "description": (
            "Vulnerability report: which of a project's dependencies have "
            "known CVEs (NVD/CISA KEV data in the graph). Supply either a "
            "list of dependencies or a repo_path whose manifests "
            "(pyproject.toml, package.json, pubspec.yaml) are parsed. "
            "Findings carry match_status 'matched' (version provably in "
            "the affected range) or 'unknown' (version/range unparseable)."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "dependencies": {
                    "type": "array",
                    "description": "Extracted dependencies: objects with name, version, ecosystem, source_file.",
                    "items": {"type": "object"},
                },
                "repo_path": {
                    "type": "string",
                    "description": "Repo path to extract dependencies from when 'dependencies' is not given.",
                },
            },
        },
    },
]


def tool_schemas() -> list[dict]:
    """OpenAI-style function schemas for the Vuln Intel tools."""
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


def vuln_report(
    tenant_id: str = "default",
    dependencies: list[dict] | None = None,
    repo_path: str | None = None,
    client: Any = None,
) -> dict[str, Any]:
    """Join dependencies against stored CVE data for ``tenant_id``."""
    from backend.retrieval.vuln_queries import vuln_report as _vuln_report

    try:
        deps = dependencies
        if deps is None and repo_path:
            from backend.ingestion.dependencies import (
                extract_dependencies_from_repo,
            )

            deps = extract_dependencies_from_repo(repo_path)
        deps = deps or []
        return _vuln_report(deps, tenant_id=tenant_id, client=client)
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("vuln_report failed: %s", e)
        return {
            "tenant_id": tenant_id,
            "dependencies_checked": 0,
            "findings": [],
            "matched_count": 0,
            "unknown_count": 0,
            "kev_count": 0,
            "error": str(e),
        }
