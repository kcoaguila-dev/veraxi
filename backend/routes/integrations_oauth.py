"""OAuth + GitHub sync routes for integrations (Phase 3).

Registered from ``routes/integrations.py``'s extension hook. The OAuth
callback is intentionally unauthenticated: the provider redirects the
browser back, and the tenant binding comes from the server-side state
record created by the authenticated ``start`` endpoint.
"""

import asyncio
import json
import logging

import sentry_sdk
from fastapi import Depends, HTTPException, Request
from fastapi.responses import RedirectResponse
from pydantic import BaseModel

from backend.services import integration_store as store
from backend.services import oauth_service

logger = logging.getLogger(__name__)


class SyncRequest(BaseModel):
    repos: list[str]
    include_issues: bool = False


def _require_supabase(_get_supabase):
    sb = _get_supabase()
    if not sb:
        raise HTTPException(
            status_code=501,
            detail="Integrations are not supported in stateless local mode",
        )
    return sb


def _redis(request: Request):
    return request.app.state.redis


def register_oauth_routes(app_router, get_tenant_id, _get_supabase, config=None):
    """Register OAuth start/callback and GitHub sync routes."""

    @app_router.get("/api/integrations/oauth/providers")
    async def list_oauth_providers(tenant_id: str = Depends(get_tenant_id)):
        """Catalog of OAuth providers (GitHub live; others structured)."""
        from backend.config import get_config

        return {"providers": oauth_service.list_providers(config or get_config())}

    @app_router.get("/api/integrations/oauth/{provider}/start")
    async def oauth_start(
        provider: str,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Begin an OAuth flow: returns the provider authorization URL."""
        from backend.config import get_config

        cfg = config or get_config()
        try:
            url = await oauth_service.build_authorize_url(
                cfg, _redis(request), provider, tenant_id
            )
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to start OAuth flow"
            ) from e
        return {"authorization_url": url, "provider": provider}

    @app_router.get("/api/integrations/oauth/{provider}/callback")
    async def oauth_callback(
        provider: str,
        request: Request,
        code: str = "",
        state: str = "",
        error: str = "",
    ):
        """Provider redirect target: exchange the code and bounce to the app."""
        from backend.config import get_config

        cfg = config or get_config()
        app_base = cfg.public_app_url.rstrip("/")
        if error or not code or not state:
            return RedirectResponse(
                f"{app_base}/#/settings/integrations?error={error or 'oauth_failed'}"
            )
        sb = _get_supabase()
        if not sb:
            return RedirectResponse(
                f"{app_base}/#/settings/integrations?error=storage_unavailable"
            )
        try:
            await oauth_service.handle_callback(
                cfg, _redis(request), sb, provider, code, state
            )
        except ValueError as e:
            logger.warning("OAuth callback rejected for %s: %s", provider, e)
            return RedirectResponse(
                f"{app_base}/#/settings/integrations?error=oauth_failed"
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            return RedirectResponse(
                f"{app_base}/#/settings/integrations?error=oauth_failed"
            )
        return RedirectResponse(
            f"{app_base}/#/settings/integrations?connected={provider}"
        )

    @app_router.post("/api/integrations/{integration_id}/sync")
    async def sync_integration(
        integration_id: str,
        payload: SyncRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Sync GitHub repos into the knowledge graph (ARQ or inline)."""
        sb = _require_supabase(_get_supabase)
        if not payload.repos:
            raise HTTPException(status_code=400, detail="repos must not be empty")
        try:
            row = await asyncio.to_thread(
                store.get_integration, sb, tenant_id, integration_id
            )
            if not row:
                raise HTTPException(status_code=404, detail="Integration not found")
            if row.get("provider") != "github":
                raise HTTPException(
                    status_code=400,
                    detail="Sync is only supported for GitHub integrations",
                )
            from backend.config import get_config

            cfg = config or get_config()
            redis = _redis(request)
            if cfg.worker_mode == "arq":
                try:
                    await redis.enqueue_job(
                        "sync_github_repo_task",
                        tenant_id,
                        integration_id,
                        payload.repos,
                        payload.include_issues,
                    )
                    return {"status": "queued", "repos": payload.repos}
                except Exception as e:
                    sentry_sdk.capture_exception(e)
                    logger.warning(
                        "ARQ enqueue failed, falling back to inline sync: %s", e
                    )
            schema = None
            schema_json = await redis.get(f"tenant:{tenant_id}:schema")
            if schema_json:
                schema = json.loads(schema_json)
            from backend.services.github_sync import run_sync_for_integration

            result = await run_sync_for_integration(
                sb,
                tenant_id,
                integration_id,
                payload.repos,
                payload.include_issues,
                schema,
            )
            return result
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error("GitHub sync request failed: %s", e)
            raise HTTPException(status_code=500, detail="Failed to sync") from e
