"""Repo X-Ray & Vuln Intel endpoints (Evidence-First GUI Phase 3).

Follows the ``routes/usage.py`` / ``routes/memories.py`` registration
pattern. The work itself lives in ``backend.ingestion.code_graph``,
``backend.retrieval.code_queries``, ``backend.ingestion.vuln_intel``,
``backend.ingestion.dependencies`` and
``backend.retrieval.vuln_queries`` — this module is the HTTP boundary:
path validation, error mapping and Sentry reporting.

Security: ``repo_path`` is never trusted. It must resolve (after
``realpath``) inside one of the allowed roots — the same roots
``routes/files.py`` serves documents from, plus any roots the
operator lists in ``VERAXI_CODE_ROOTS`` (``os.pathsep``-separated).
The scandir-based ``_resolve_inside_allowed_dirs`` helper used by
``routes/files.py`` resolves *files* only (its final segment must be
a file), so directory targets are validated here with the same
fail-closed semantics: null bytes, ``..`` segments and anything
outside the allowed roots are rejected before any filesystem walk.
"""

import logging
import os

import sentry_sdk
from fastapi import Depends, HTTPException
from pydantic import BaseModel

from backend.ingestion.code_graph import write_repo_code_graph
from backend.ingestion.dependencies import extract_dependencies_from_repo
from backend.ingestion.vuln_intel import fetch_and_write_vuln_intel
from backend.retrieval.code_queries import impact_analysis, repo_overview, symbol_lookup
from backend.retrieval.vuln_queries import vuln_report

logger = logging.getLogger(__name__)


def _allowed_roots() -> list[str]:
    """Directories a repo_path may live under (files.py roots + env)."""
    roots = [
        os.getcwd(),
        "/app/data",
        os.path.expanduser("~/Documents/book"),
        "/home/ubuntu/Documents/book",
    ]
    custom_dir = os.environ.get("DOCUMENTS_DIR")
    if custom_dir:
        roots.append(custom_dir)
    extra = os.environ.get("VERAXI_CODE_ROOTS")
    if extra:
        roots.extend(p for p in extra.split(os.pathsep) if p)
    return [os.path.realpath(r) for r in roots]


def _validate_repo_path(raw_path: str) -> str:
    """Resolve ``raw_path`` to an existing directory inside the roots.

    Raises HTTPException 400 for malformed input, 403 for paths that
    try to escape the allowed roots, 404 for missing directories.
    """
    if not raw_path or "\x00" in raw_path:
        raise HTTPException(status_code=400, detail="repo_path required")
    parts = raw_path.replace("\\", "/").split("/")
    if ".." in parts:
        raise HTTPException(status_code=403, detail="Path traversal is forbidden")
    resolved = os.path.realpath(raw_path)
    for root in _allowed_roots():
        try:
            if os.path.commonpath([root, resolved]) == root:
                if not os.path.isdir(resolved):
                    raise HTTPException(
                        status_code=404, detail="Repository path not found"
                    )
                return resolved
        except ValueError:
            continue
    raise HTTPException(
        status_code=403, detail="Repository path is outside the allowed roots"
    )


class CodeIngestRequest(BaseModel):
    repo_path: str


class VulnReportRequest(BaseModel):
    repo_path: str | None = None
    dependencies: list[dict] | None = None


def _default_neo4j_client():
    """Build the production Neo4j storage client from config.

    Same construction ``code_graph.write_repo_code_graph`` uses when
    no client is injected (``Neo4jStorageClient.from_config``).
    """
    from backend.config import get_config
    from backend.storage.neo4j_client import Neo4jStorageClient

    return Neo4jStorageClient.from_config(get_config())


def _sync_vuln_intel(tenant_id: str) -> dict:
    """Fetch NVD + CISA KEV and write them for ``tenant_id``.

    The NVD API key, when configured, comes from the ``NVD_API_KEY``
    environment variable inside ``fetch_and_write_vuln_intel``.
    """
    return fetch_and_write_vuln_intel(
        _default_neo4j_client(), tenant_id=tenant_id
    )


def register_code_intel_routes(
    app_router, get_tenant_id, _get_supabase=None, config=None
):
    """Register Repo X-Ray and Vuln Intel routes."""

    @app_router.post("/api/v1/code/ingest")
    async def ingest_code_graph(
        payload: CodeIngestRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Parse a repo into the code graph for this tenant."""
        resolved = _validate_repo_path(payload.repo_path)
        try:
            counts = write_repo_code_graph(resolved, tenant_id=tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to index code graph"
            ) from e
        return {"status": "ok", "repo_path": resolved, **counts}

    @app_router.get("/api/v1/code/overview")
    async def get_code_overview(tenant_id: str = Depends(get_tenant_id)):
        """Node/edge counts plus the most-connected symbols."""
        try:
            return repo_overview(tenant_id=tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to load code overview"
            ) from e

    @app_router.get("/api/v1/code/symbol")
    async def get_code_symbol(
        name: str = "", tenant_id: str = Depends(get_tenant_id)
    ):
        """Look up a code symbol by qualified or simple name."""
        try:
            return symbol_lookup(name, tenant_id=tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to look up symbol"
            ) from e

    @app_router.get("/api/v1/code/impact")
    async def get_code_impact(
        symbol: str = "",
        max_depth: int = 3,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Reverse-dependency impact tree for a symbol."""
        try:
            return impact_analysis(symbol, tenant_id=tenant_id, max_depth=max_depth)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to run impact analysis"
            ) from e

    @app_router.post("/api/v1/vuln/sync")
    async def sync_vuln(tenant_id: str = Depends(get_tenant_id)):
        """Fetch the latest NVD + CISA KEV data into the graph."""
        try:
            counts = _sync_vuln_intel(tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to sync vulnerability intel"
            ) from e
        return {"status": "ok", **counts}

    @app_router.post("/api/v1/vuln/report")
    async def get_vuln_report(
        payload: VulnReportRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Join a repo's (or an explicit list of) dependencies to CVEs."""
        if payload.dependencies is not None:
            dependencies = payload.dependencies
        elif payload.repo_path:
            resolved = _validate_repo_path(payload.repo_path)
            dependencies = extract_dependencies_from_repo(resolved)
        else:
            raise HTTPException(
                status_code=400,
                detail="Provide either repo_path or dependencies",
            )
        try:
            return vuln_report(dependencies, tenant_id=tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to build vulnerability report"
            ) from e
