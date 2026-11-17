"""OpenAPI import routes for integrations (Phase 4).

Registered from ``routes/integrations.py``'s extension hook.
"""

import asyncio
import logging

import httpx
from fastapi import Depends, HTTPException
from pydantic import BaseModel

from backend.security.ssrf import SsrfBlockedError
from backend.services import integration_store as store
from backend.services import openapi_importer

logger = logging.getLogger(__name__)


class OpenApiPreviewRequest(BaseModel):
    spec_text: str | None = None
    spec_url: str | None = None


class OpenApiCreateRequest(BaseModel):
    display_name: str | None = None
    spec_text: str | None = None
    spec_url: str | None = None
    selected_operation_ids: list[str]
    server_url: str | None = None
    auth_type: str = "bearer"  # bearer | api_key_header | api_key_query
    auth_value: str | None = None
    auth_name: str | None = None  # header/query name for api_key auth


def _require_supabase(_get_supabase):
    sb = _get_supabase()
    if not sb:
        raise HTTPException(
            status_code=501,
            detail="Integrations are not supported in stateless local mode",
        )
    return sb


async def _load_spec(payload: OpenApiPreviewRequest | OpenApiCreateRequest) -> dict:
    if payload.spec_text:
        return openapi_importer.parse_spec(payload.spec_text)
    if payload.spec_url:
        try:
            text = await openapi_importer.fetch_spec_text(payload.spec_url)
        except SsrfBlockedError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        except httpx.HTTPError as e:
            raise HTTPException(
                status_code=502, detail="Could not fetch the OpenAPI spec URL"
            ) from e
        return openapi_importer.parse_spec(text)
    raise HTTPException(
        status_code=400, detail="Provide spec_text or spec_url"
    )


def register_openapi_routes(app_router, get_tenant_id, _get_supabase, config=None):
    """Register the OpenAPI preview/create routes."""

    @app_router.post("/api/integrations/openapi/preview")
    async def preview_openapi(
        payload: OpenApiPreviewRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Parse a spec and return its selectable operations."""
        try:
            spec = await _load_spec(payload)
        except HTTPException:
            raise
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        operations = openapi_importer.list_operations(spec)
        info = spec.get("info") or {}
        return {
            "title": info.get("title", ""),
            "version": info.get("version", ""),
            "operations": operations,
            "max_operations": openapi_importer.MAX_OPERATIONS,
        }

    @app_router.post("/api/integrations/openapi", status_code=201)
    async def create_openapi(
        payload: OpenApiCreateRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Save selected operations + encrypted auth as an integration."""
        sb = _require_supabase(_get_supabase)
        if payload.auth_type not in ("bearer", "api_key_header", "api_key_query"):
            raise HTTPException(status_code=400, detail="Unsupported auth_type")
        try:
            spec = await _load_spec(payload)
            operations = openapi_importer.compile_operations(
                spec,
                payload.selected_operation_ids,
                server_url_override=payload.server_url or "",
            )
        except HTTPException:
            raise
        except (ValueError, SsrfBlockedError) as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        info = spec.get("info") or {}
        display_name = (payload.display_name or "").strip() or info.get(
            "title", "OpenAPI Integration"
        )
        auth_config = {"type": payload.auth_type}
        if payload.auth_name:
            auth_config["name"] = payload.auth_name
        secrets = None
        if payload.auth_value:
            key = "access_token" if payload.auth_type == "bearer" else "api_key"
            secrets = {key: payload.auth_value}
        try:
            slug = await asyncio.to_thread(
                store.unique_slug, sb, tenant_id, display_name
            )
            row = await asyncio.to_thread(
                store.create_integration,
                sb,
                tenant_id,
                kind="openapi",
                provider="custom_openapi",
                slug=slug,
                display_name=display_name,
                config={
                    "operations": operations,
                    "auth": auth_config,
                    "spec_title": info.get("title", ""),
                },
                secrets=secrets,
            )
            return store.public_view(row)
        except HTTPException:
            raise
        except Exception as e:
            store.report_error(e)
            raise HTTPException(
                status_code=500, detail="Failed to create integration"
            ) from e
