"""External integrations endpoints (MCP servers, OAuth, OpenAPI).

Follows the ``routes/api_keys.py`` registration pattern: routes are
registered with injected auth dependencies and reach Supabase through
the gateway's ``_get_supabase``. When Supabase is unavailable (stateless
local mode) the endpoints return 501, matching the API-key precedent.

Secrets are never returned: list/get responses go through
:func:`backend.services.integration_store.public_view`, which exposes
only a ``has_auth`` boolean.
"""

import asyncio
import logging
import time
from urllib.parse import urlparse

import sentry_sdk
from fastapi import Depends, HTTPException, Request
from pydantic import BaseModel

from backend.security.ssrf import SsrfBlockedError, validate_external_url
from backend.services import integration_store as store

logger = logging.getLogger(__name__)


class McpIntegrationCreateRequest(BaseModel):
    display_name: str | None = None
    url: str
    transport: str = "auto"  # auto | streamable_http | sse
    headers: dict[str, str] | None = None


class IntegrationPatchRequest(BaseModel):
    display_name: str | None = None
    is_enabled: bool | None = None
    config: dict | None = None
    secrets: dict | None = None


async def _probe_mcp_server(url: str, headers: dict[str, str], transport: str) -> list[str]:
    """Handshake seam: connect to an MCP server and list its tool names.

    Phase 1 implements this directly on the MCP SDK; the hardened
    runtime in ``services/mcp_client_manager.py`` supersedes it for chat
    traffic. Tests patch this seam instead of opening real connections.
    """
    from backend.services.mcp_probe import probe_mcp_tools

    return await probe_mcp_tools(url, headers, transport)


def _invalidate_mcp_cache(row: dict | None) -> None:
    """Drop cached MCP tool schemas for an integration's server URL."""
    if not row:
        return
    try:
        from backend.services.mcp_client_manager import invalidate_cache

        invalidate_cache(
            integration_id=str(row.get("id") or "") or None,
            tenant_id=str(row.get("tenant_id") or "") or None,
        )
    except Exception as e:  # Cache invalidation must never fail a request.
        sentry_sdk.capture_exception(e)
        logger.warning("Failed to invalidate MCP manager cache: %s", e)
    url = (row.get("config") or {}).get("url")
    if not url:
        return
    try:
        from backend.mcp_server.tool_dispatch import _MCP_TOOL_CACHE

        _MCP_TOOL_CACHE.pop(url, None)
    except Exception as e:  # Cache invalidation must never fail a request.
        sentry_sdk.capture_exception(e)
        logger.warning("Failed to invalidate MCP tool cache for %s: %s", url, e)


def _require_supabase(_get_supabase):
    sb = _get_supabase()
    if not sb:
        raise HTTPException(
            status_code=501,
            detail="Integrations are not supported in stateless local mode",
        )
    return sb


def register_integration_routes(app_router, get_tenant_id, _get_supabase, config=None):
    """Register all integration routes with injected auth dependencies."""

    @app_router.get("/api/integrations")
    async def list_integrations(tenant_id: str = Depends(get_tenant_id)):
        """List the tenant's integrations (secrets masked to has_auth)."""
        sb = _require_supabase(_get_supabase)
        try:
            rows = await asyncio.to_thread(
                store.list_integrations, sb, tenant_id, include_secrets=True
            )
            return {"integrations": [store.public_view(r) for r in rows]}
        except HTTPException:
            raise
        except Exception as e:
            store.report_error(e)
            raise HTTPException(
                status_code=500, detail="Failed to list integrations"
            ) from e

    @app_router.post("/api/integrations/mcp", status_code=201)
    async def create_mcp_integration(
        payload: McpIntegrationCreateRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Validate, handshake-test, and persist a custom MCP server."""
        sb = _require_supabase(_get_supabase)
        if payload.transport not in ("auto", "streamable_http", "sse"):
            raise HTTPException(
                status_code=400,
                detail="transport must be auto, streamable_http, or sse",
            )
        try:
            validate_external_url(payload.url)
        except SsrfBlockedError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        display_name = (payload.display_name or "").strip()
        if not display_name:
            display_name = urlparse(payload.url).hostname or "MCP Server"
        headers = payload.headers or {}
        try:
            tool_names = await _probe_mcp_server(payload.url, headers, payload.transport)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=502,
                detail="Could not connect to the MCP server or complete the handshake",
            ) from e
        try:
            slug = await asyncio.to_thread(
                store.unique_slug, sb, tenant_id, display_name
            )
            row = await asyncio.to_thread(
                store.create_integration,
                sb,
                tenant_id,
                kind="mcp",
                provider="custom_mcp",
                slug=slug,
                display_name=display_name,
                config={
                    "url": payload.url,
                    "transport": payload.transport,
                    "tool_names": tool_names,
                },
                secrets={"headers": headers} if headers else None,
            )
            return store.public_view(row)
        except HTTPException:
            raise
        except Exception as e:
            store.report_error(e)
            raise HTTPException(
                status_code=500, detail="Failed to create integration"
            ) from e

    @app_router.patch("/api/integrations/{integration_id}")
    async def patch_integration(
        integration_id: str,
        payload: IntegrationPatchRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Update name/config/secrets or toggle an integration."""
        sb = _require_supabase(_get_supabase)
        try:
            existing = await asyncio.to_thread(
                store.get_integration, sb, tenant_id, integration_id
            )
            if not existing:
                raise HTTPException(status_code=404, detail="Integration not found")
            merged_config = None
            if payload.config is not None:
                merged_config = {**(existing.get("config") or {}), **payload.config}
                if "url" in payload.config:
                    try:
                        validate_external_url(str(payload.config["url"]))
                    except SsrfBlockedError as e:
                        raise HTTPException(status_code=400, detail=str(e)) from e
            merged_secrets = None
            if payload.secrets is not None:
                current = store.decrypt_row_secrets(existing)
                merged_secrets = {**current, **payload.secrets}
            row = await asyncio.to_thread(
                store.update_integration,
                sb,
                tenant_id,
                integration_id,
                display_name=payload.display_name,
                config=merged_config,
                secrets=merged_secrets,
                is_enabled=payload.is_enabled,
            )
            if not row:
                raise HTTPException(status_code=404, detail="Integration not found")
            _invalidate_mcp_cache(row)
            return store.public_view(row)
        except HTTPException:
            raise
        except Exception as e:
            store.report_error(e)
            raise HTTPException(
                status_code=500, detail="Failed to update integration"
            ) from e

    @app_router.delete("/api/integrations/{integration_id}")
    async def delete_integration(
        integration_id: str,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Delete an integration and invalidate its MCP cache entry."""
        sb = _require_supabase(_get_supabase)
        try:
            existing = await asyncio.to_thread(
                store.get_integration, sb, tenant_id, integration_id
            )
            if not existing:
                raise HTTPException(status_code=404, detail="Integration not found")
            await asyncio.to_thread(
                store.delete_integration, sb, tenant_id, integration_id
            )
            _invalidate_mcp_cache(existing)
            return {"status": "deleted"}
        except HTTPException:
            raise
        except Exception as e:
            store.report_error(e)
            raise HTTPException(
                status_code=500, detail="Failed to delete integration"
            ) from e

    @app_router.post("/api/integrations/{integration_id}/test")
    async def test_integration(
        integration_id: str,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Run a live connectivity/tool-discovery check for an MCP integration."""
        sb = _require_supabase(_get_supabase)
        try:
            row = await asyncio.to_thread(
                store.get_integration, sb, tenant_id, integration_id
            )
            if not row:
                raise HTTPException(status_code=404, detail="Integration not found")
            if row.get("kind") != "mcp":
                raise HTTPException(
                    status_code=400,
                    detail="Connection test is only supported for MCP integrations",
                )
            cfg = row.get("config") or {}
            url = cfg.get("url", "")
            try:
                validate_external_url(url)
            except SsrfBlockedError as e:
                raise HTTPException(status_code=400, detail=str(e)) from e
            secrets = store.decrypt_row_secrets(row)
            headers = secrets.get("headers") or {}
            started = time.monotonic()
            try:
                tool_names = await _probe_mcp_server(
                    url, headers, cfg.get("transport", "auto")
                )
            except Exception as e:
                sentry_sdk.capture_exception(e)
                await asyncio.to_thread(
                    store.update_integration,
                    sb,
                    tenant_id,
                    integration_id,
                    status="error",
                )
                raise HTTPException(
                    status_code=502,
                    detail="Could not connect to the MCP server or complete the handshake",
                ) from e
            latency_ms = int((time.monotonic() - started) * 1000)
            new_config = {**cfg, "tool_names": tool_names}
            await asyncio.to_thread(
                store.update_integration,
                sb,
                tenant_id,
                integration_id,
                config=new_config,
                status="connected",
            )
            _invalidate_mcp_cache(row)
            return {
                "status": "connected",
                "tools": tool_names,
                "tool_count": len(tool_names),
                "latency_ms": latency_ms,
            }
        except HTTPException:
            raise
        except Exception as e:
            store.report_error(e)
            raise HTTPException(
                status_code=500, detail="Failed to test integration"
            ) from e

    # Placeholder anchor: OAuth, sync, and OpenAPI route registrations
    # are added by register_integration_extension_routes below.
    register_integration_extension_routes(
        app_router, get_tenant_id, _get_supabase, config
    )


def register_integration_extension_routes(
    app_router, get_tenant_id, _get_supabase, config=None
):
    """Extension routes (OAuth/OpenAPI/sync) registered by later phases.

    Kept as a separate function so each stacked phase extends the
    integrations surface without rewriting the Phase 1 CRUD block.
    """
    try:
        from backend.routes.integrations_oauth import register_oauth_routes

        register_oauth_routes(app_router, get_tenant_id, _get_supabase, config)
    except ImportError:
        pass
    try:
        from backend.routes.integrations_openapi import register_openapi_routes

        register_openapi_routes(app_router, get_tenant_id, _get_supabase, config)
    except ImportError:
        pass


# Re-exported for tests that patch the request object type.
__all__ = ["Request", "register_integration_routes"]
