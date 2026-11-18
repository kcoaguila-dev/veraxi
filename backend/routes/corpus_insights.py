"""Corpus briefing & dbt lineage endpoints (Evidence-First GUI Phase 2).

Follows the ``routes/usage.py`` / ``routes/memories.py`` registration
pattern: routes are registered with the gateway's injected
``get_tenant_id`` dependency. The graph work itself lives in
``backend.retrieval.corpus_briefing`` (briefing),
``backend.ingestion.dbt_lineage`` (manifest parsing/writing) and
``backend.retrieval.dbt_queries`` (dataset discovery) — this module
is only the HTTP boundary: validation, size caps and error mapping.
"""

import json
import logging

import sentry_sdk
from fastapi import Depends, HTTPException
from pydantic import BaseModel

from backend.ingestion.dbt_lineage import parse_dbt_manifest, write_dbt_graph
from backend.retrieval.corpus_briefing import build_briefing, render_briefing_markdown
from backend.retrieval.dbt_queries import dataset_discovery

logger = logging.getLogger(__name__)

# A dbt manifest for a real project is a few MB of JSON; anything far
# beyond that is not a manifest upload but a misuse of the endpoint.
MAX_MANIFEST_BYTES = 10 * 1024 * 1024


class DbtIngestRequest(BaseModel):
    manifest: dict


def _default_neo4j_client():
    """Build the production Neo4j storage client from config."""
    from backend.config import get_config
    from backend.storage.neo4j_client import Neo4jStorageClient

    return Neo4jStorageClient.from_config(get_config())


def _write_dbt_graph(graph, tenant_id: str) -> dict:
    """Persist a parsed dbt graph via the default storage client."""
    return write_dbt_graph(_default_neo4j_client(), graph, tenant_id=tenant_id)


def register_corpus_insights_routes(
    app_router, get_tenant_id, _get_supabase=None, config=None
):
    """Register corpus-briefing and dbt-lineage routes."""

    @app_router.get("/api/v1/corpus/briefing")
    async def get_corpus_briefing(tenant_id: str = Depends(get_tenant_id)):
        """Return the deterministic corpus briefing as JSON + markdown."""
        try:
            briefing = build_briefing(tenant_id=tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to build corpus briefing"
            ) from e
        return {**briefing, "markdown": render_briefing_markdown(briefing)}

    @app_router.post("/api/v1/dbt/ingest")
    async def ingest_dbt_manifest(
        payload: DbtIngestRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Validate and ingest a dbt manifest.json payload.

        The body is JSON (``{"manifest": {...}}``) rather than
        multipart so no new dependency is needed; the manifest dict
        must carry a ``nodes`` mapping, exactly as dbt writes it.
        """
        manifest = payload.manifest
        if not isinstance(manifest.get("nodes"), dict):
            raise HTTPException(
                status_code=400,
                detail="Manifest must be a dbt manifest object with a 'nodes' mapping",
            )
        if len(json.dumps(manifest)) > MAX_MANIFEST_BYTES:
            raise HTTPException(
                status_code=413, detail="Manifest payload too large"
            )
        try:
            graph = parse_dbt_manifest(manifest)
            counts = _write_dbt_graph(graph, tenant_id)
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to ingest dbt manifest"
            ) from e
        return {"status": "ok", **counts}

    @app_router.get("/api/v1/dbt/datasets")
    async def search_datasets(
        q: str = "", tenant_id: str = Depends(get_tenant_id)
    ):
        """Search datasets/models by name fragment or exact column name."""
        try:
            return dataset_discovery(q, tenant_id=tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to search datasets"
            ) from e
