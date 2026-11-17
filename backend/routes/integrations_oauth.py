"""OAuth + GitHub sync routes for integrations (Phase 3).

Registered from ``routes/integrations.py``'s extension hook. The OAuth
callback is intentionally unauthenticated: the provider redirects the
browser back, and the tenant binding comes from the server-side state
record created by the authenticated ``start`` endpoint.
"""

import asyncio
import html
import json
import logging
from urllib.parse import urlparse

import sentry_sdk
from fastapi import Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
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


def _app_origin(app_base: str) -> str:
    parsed = urlparse(app_base)
    if parsed.scheme and parsed.netloc:
        return f"{parsed.scheme}://{parsed.netloc}"
    return "*"


def _oauth_callback_html(
    app_base: str,
    provider: str,
    status: str,
    error: str = "",
) -> HTMLResponse:
    """Return a self-closing popup page that notifies the opener via postMessage.

    Falls back to redirecting to the clean ``/#/chat`` route when opened
    without ``window.opener`` (e.g. popup-blocked or mobile browser).
    """
    clean_app_url = f"{app_base.rstrip('/')}/#/chat"
    target_origin = _app_origin(app_base)
    payload_json = json.dumps({
        "type": "veraxi_oauth_callback",
        "provider": provider,
        "status": status,
        "error": error,
    })
    origin_json = json.dumps(target_origin)
    fallback_json = json.dumps(clean_app_url)
    heading = (
        "Connection complete" if status == "connected" else "Authorization failed"
    )
    detail = (
        f"{html.escape(provider)} is now connected. You can close this window."
        if status == "connected"
        else f"Could not connect {html.escape(provider)}. You can close this window."
    )
    body = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Veraxi — {heading}</title>
  <style>
    body {{ font-family: system-ui, -apple-system, sans-serif; background: #121212;
           color: #e5e7eb; display: flex; align-items: center; justify-content: center;
           height: 100vh; margin: 0; text-align: center; }}
    .card {{ padding: 24px 32px; border-radius: 12px; background: #1e1e1e;
             border: 1px solid #2e2e2e; max-width: 360px; }}
    h1 {{ font-size: 18px; margin: 0 0 8px; }}
    p {{ font-size: 14px; color: #9ca3af; margin: 0; }}
  </style>
</head>
<body>
  <div class="card">
    <h1>{heading}</h1>
    <p>{detail}</p>
  </div>
  <script>
    (function () {{
      var payload = {payload_json};
      var origin = {origin_json};
      var fallback = {fallback_json};
      if (window.opener && !window.opener.closed) {{
        try {{
          window.opener.postMessage(payload, origin);
        }} catch (_) {{}}
        window.close();
        return;
      }}
      window.location.replace(fallback);
    }})();
  </script>
</body>
</html>"""
    return HTMLResponse(content=body, status_code=200)


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
            return _oauth_callback_html(
                app_base, provider, "error", error or "oauth_failed"
            )
        sb = _get_supabase()
        if not sb:
            return _oauth_callback_html(
                app_base, provider, "error", "storage_unavailable"
            )
        try:
            await oauth_service.handle_callback(
                cfg, _redis(request), sb, provider, code, state
            )
        except ValueError as e:
            logger.warning("OAuth callback rejected for %s: %s", provider, e)
            return _oauth_callback_html(
                app_base, provider, "error", "oauth_failed"
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            return _oauth_callback_html(
                app_base, provider, "error", "oauth_failed"
            )
        return _oauth_callback_html(app_base, provider, "connected")

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
