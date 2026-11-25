"""GitHub App routes: IDOR-proof installation OAuth, repo picker, indexing, and webhooks."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
from typing import Any

import sentry_sdk
from fastapi import Depends, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from backend.routes.integrations_oauth import _oauth_callback_html
from backend.services import github_app_client as gh_client
from backend.services import github_app_store as gh_store
from backend.services.github_app_ingest import (
    index_github_app_repo,
    purge_github_app_repo,
)

logger = logging.getLogger(__name__)

_DELIVERY_TTL_SEC = 86400
_JOB_OWNER_TTL_SEC = 3600
_USER_REFRESH_LOCK_TTL_SEC = 30
_USER_REFRESH_WAIT_ATTEMPTS = 12
_USER_REFRESH_WAIT_INTERVAL_SEC = 0.15


class GitHubAppIndexRequest(BaseModel):
    installation_id: int
    repo_full_name: str = Field(..., min_length=3)
    branch: str | None = None
    auto_sync_on_push: bool = True


def _require_supabase(_get_supabase):
    sb = _get_supabase() if _get_supabase else None
    if not sb:
        raise HTTPException(
            status_code=501,
            detail="GitHub App integrations require Supabase storage",
        )
    return sb


def _redis(request: Request):
    return getattr(getattr(request, "app", None), "state", None) and getattr(
        request.app.state, "redis", None
    )


def _cfg(config):
    if config is not None:
        return config
    from backend.config import get_config

    return get_config()


async def _wait_for_concurrent_refresh(
    sb: Any, tenant_id: str, installation_id: int, fallback_token: str
) -> str | None:
    """Wait briefly for another worker's token refresh, then re-read Supabase."""
    for _ in range(_USER_REFRESH_WAIT_ATTEMPTS):
        await asyncio.sleep(_USER_REFRESH_WAIT_INTERVAL_SEC)
        fresh = await asyncio.to_thread(
            gh_store.get_installation, sb, tenant_id, installation_id
        )
        if fresh and not gh_store.user_token_expired(fresh):
            return gh_store.decrypt_user_tokens(fresh).get("access_token") or None
    return fallback_token or None


async def _valid_user_token(
    cfg: Any, sb: Any, redis_client: Any, inst: dict[str, Any]
) -> str | None:
    """Return a valid user-to-server token for ``inst``, refreshing under a Redis lock."""
    tokens = gh_store.decrypt_user_tokens(inst)
    access_token = tokens.get("access_token") or ""
    if access_token and not gh_store.user_token_expired(inst):
        return access_token
    refresh_token = tokens.get("refresh_token") or ""
    if not refresh_token:
        return access_token or None

    tenant_id = inst["tenant_id"]
    installation_id = int(inst["installation_id"])
    lock_key = f"ghapp:refresh-lock:{tenant_id}:{installation_id}"
    lock_acquired = True
    if redis_client is not None:
        lock_acquired = bool(
            await redis_client.set(lock_key, "1", nx=True, ex=_USER_REFRESH_LOCK_TTL_SEC)
        )
    if not lock_acquired:
        return await _wait_for_concurrent_refresh(
            sb, tenant_id, installation_id, access_token
        )

    try:
        # Double-check after acquiring lock in case a peer finished moments earlier.
        fresh = await asyncio.to_thread(
            gh_store.get_installation, sb, tenant_id, installation_id
        )
        if fresh and not gh_store.user_token_expired(fresh):
            fresh_tok = gh_store.decrypt_user_tokens(fresh).get("access_token") or ""
            if fresh_tok:
                return fresh_tok
        if fresh:
            refresh_token = gh_store.decrypt_user_tokens(fresh).get("refresh_token") or refresh_token

        refreshed = await gh_client.refresh_user_token(cfg, refresh_token)
        merged = {
            "access_token": refreshed["access_token"],
            "refresh_token": refreshed.get("refresh_token") or refresh_token,
        }
        await asyncio.to_thread(
            gh_store.upsert_installation,
            sb,
            tenant_id,
            installation_id=installation_id,
            account_id=int(inst["github_account_id"]),
            account_login=inst["github_account_login"],
            account_type=inst["github_account_type"],
            repository_selection=inst.get("repository_selection") or "selected",
            permissions=inst.get("permissions") or {},
            user_tokens=merged,
            user_token_expires_at=gh_store.token_expires_at_iso(refreshed.get("expires_in")),
            status=inst.get("status") or "active",
        )
        return str(refreshed["access_token"])
    finally:
        if redis_client is not None:
            try:
                await redis_client.delete(lock_key)
            except Exception as exc:
                sentry_sdk.capture_exception(exc)
                logger.warning("Failed to release GitHub App refresh lock: %s", exc)


def _verify_webhook_signature(secret: str, body: bytes, signature: str) -> None:
    if not secret:
        raise HTTPException(
            status_code=503,
            detail="GITHUB_APP_WEBHOOK_SECRET is not configured",
        )
    if not signature or not signature.startswith("sha256="):
        raise HTTPException(status_code=401, detail="Missing webhook signature")
    expected = (
        "sha256="
        + hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    )
    if not hmac.compare_digest(signature, expected):
        raise HTTPException(status_code=401, detail="Invalid webhook signature")


async def _is_duplicate_delivery(redis_client: Any, delivery_id: str) -> bool:
    if not redis_client or not delivery_id:
        return False
    acquired = await redis_client.set(
        f"ghapp:delivery:{delivery_id}", "1", nx=True, ex=_DELIVERY_TTL_SEC
    )
    return not bool(acquired)


async def _collect_installation_repos(
    cfg: Any,
    sb: Any,
    redis_client: Any,
    installations: list[dict[str, Any]],
    indexed_by_name: dict[str, dict[str, Any]],
    needle: str,
) -> list[dict[str, Any]]:
    """Fetch user-visible repositories across installations and merge index status."""
    items: list[dict[str, Any]] = []
    for inst in installations:
        if inst.get("status") == "deleted":
            continue
        inst_id = int(inst["installation_id"])
        try:
            user_token = await _valid_user_token(cfg, sb, redis_client, inst)
            if not user_token:
                continue
            gh_repos = await gh_client.list_user_installation_repos(
                user_token, inst_id
            )
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning(
                "Failed listing GitHub App repos for installation %s: %s",
                inst_id,
                exc,
            )
            continue
        for r in gh_repos:
            full_name = str(r.get("full_name") or "")
            if not full_name:
                continue
            if needle and needle not in full_name.lower():
                continue
            tracked = indexed_by_name.get(full_name) or {}
            items.append(
                {
                    "installation_id": inst_id,
                    "account_login": inst.get("github_account_login"),
                    "github_repo_id": r.get("id"),
                    "full_name": full_name,
                    "default_branch": r.get("default_branch") or "main",
                    "private": bool(r.get("private", True)),
                    "index_status": tracked.get("index_status") or "available",
                    "auto_sync_on_push": tracked.get("auto_sync_on_push", True),
                    "last_indexed_sha": tracked.get("last_indexed_sha"),
                    "last_indexed_at": tracked.get("last_indexed_at"),
                    "last_error": tracked.get("last_error"),
                }
            )
    return items


async def _verify_repo_access(
    cfg: Any,
    sb: Any,
    redis_client: Any,
    tenant_id: str,
    installation_id: int,
    repo_full_name: str,
) -> dict[str, Any]:
    """Ensure ``tenant_id`` owns ``installation_id`` and can access ``repo_full_name``."""
    inst = await asyncio.to_thread(
        gh_store.get_installation, sb, tenant_id, installation_id
    )
    if not inst or inst.get("status") == "deleted":
        raise HTTPException(
            status_code=404, detail="GitHub App installation not found"
        )
    user_token = await _valid_user_token(cfg, sb, redis_client, inst)
    if not user_token:
        raise HTTPException(
            status_code=401, detail="GitHub user authorization expired; reconnect"
        )
    gh_repos = await gh_client.list_user_installation_repos(
        user_token, installation_id
    )
    matched = next(
        (r for r in gh_repos if r.get("full_name") == repo_full_name),
        None,
    )
    if matched is None:
        raise HTTPException(
            status_code=403,
            detail="Repository is not accessible under this GitHub App installation",
        )
    return matched


async def _dispatch_repo_purges(
    cfg: Any, redis_client: Any, targets: list[tuple[str, str]]
) -> str:
    """Purge Neo4j graphs via ARQ when enabled, otherwise inline."""
    if not targets:
        return "purged"
    if cfg.worker_mode == "arq" and redis_client is not None:
        try:
            await redis_client.enqueue_job(
                "purge_github_app_repos_task",
                [[tid, repo] for tid, repo in targets],
            )
            return "queued"
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning("Failed to enqueue repo purge, falling back inline: %s", exc)
    for tid, repo in targets:
        await purge_github_app_repo(tid, repo)
    return "purged"


async def _handle_installation_event(
    cfg: Any, sb: Any, redis_client: Any, payload: dict[str, Any]
) -> dict[str, Any]:
    action = payload.get("action") or ""
    inst = payload.get("installation") or {}
    inst_id = inst.get("id")
    if not inst_id:
        return {"status": "ignored", "reason": "missing installation id"}
    inst_id = int(inst_id)

    if action == "deleted":
        rows = await asyncio.to_thread(
            gh_store.find_installations_by_github_id, sb, inst_id
        )
        targets: list[tuple[str, str]] = []
        for row in rows:
            tenant_repos = await asyncio.to_thread(gh_store.list_repos, sb, row["tenant_id"])
            for repo_row in tenant_repos:
                if int(repo_row.get("installation_id") or 0) == inst_id:
                    targets.append((row["tenant_id"], repo_row["repo_full_name"]))
        # Revoke Supabase access and installation token synchronously first.
        await asyncio.to_thread(gh_store.delete_installation_for_all_tenants, sb, inst_id)
        await gh_client.invalidate_installation_token(redis_client, inst_id)
        purge_status = await _dispatch_repo_purges(cfg, redis_client, targets)
        return {"status": purge_status, "installation_id": inst_id}

    if action in ("suspend", "unsuspend", "new_permissions_accepted"):
        new_status = "suspended" if action == "suspend" else "active"
        await asyncio.to_thread(
            gh_store.update_installation_status,
            sb,
            inst_id,
            status=new_status,
            repository_selection=inst.get("repository_selection"),
            permissions=inst.get("permissions"),
        )
        if action == "suspend":
            await gh_client.invalidate_installation_token(redis_client, inst_id)
        return {"status": "updated", "installation_id": inst_id, "action": action}

    return {"status": "ignored", "action": action}


async def _handle_installation_repos_event(
    cfg: Any, sb: Any, redis_client: Any, payload: dict[str, Any]
) -> dict[str, Any]:
    action = payload.get("action") or ""
    inst_id = int((payload.get("installation") or {}).get("id") or 0)
    if not inst_id:
        return {"status": "ignored", "reason": "missing installation id"}

    if action == "removed":
        removed = payload.get("repositories_removed") or []
        inst_rows = await asyncio.to_thread(
            gh_store.find_installations_by_github_id, sb, inst_id
        )
        targets: list[tuple[str, str]] = []
        for repo in removed:
            full_name = repo.get("full_name")
            if not full_name:
                continue
            for inst_row in inst_rows:
                tid = inst_row["tenant_id"]
                await asyncio.to_thread(gh_store.delete_repo, sb, tid, full_name)
                targets.append((tid, full_name))
        await _dispatch_repo_purges(cfg, redis_client, targets)
        return {"status": "removed", "count": len(removed)}

    return {"status": "ok", "action": action}


async def _handle_repository_deleted_event(
    sb: Any, payload: dict[str, Any]
) -> dict[str, Any]:
    inst_id = int((payload.get("installation") or {}).get("id") or 0)
    full_name = (payload.get("repository") or {}).get("full_name") or ""
    if inst_id and full_name:
        rows = await asyncio.to_thread(
            gh_store.find_repos_by_installation_and_name, sb, inst_id, full_name
        )
        for row in rows:
            await purge_github_app_repo(row["tenant_id"], full_name)
            await asyncio.to_thread(gh_store.delete_repo, sb, row["tenant_id"], full_name)
    return {"status": "purged", "repo": full_name}


async def _handle_push_event(
    cfg: Any, sb: Any, redis_client: Any, payload: dict[str, Any]
) -> dict[str, Any]:
    inst_id = int((payload.get("installation") or {}).get("id") or 0)
    repo_full_name = (payload.get("repository") or {}).get("full_name") or ""
    after_sha = payload.get("after") or ""
    ref = payload.get("ref") or ""
    if not inst_id or not repo_full_name or not after_sha or set(after_sha) == {"0"}:
        return {"status": "ignored", "reason": "non-target push"}

    branch = ref.removeprefix("refs/heads/") if ref.startswith("refs/heads/") else None
    if cfg.worker_mode == "arq" and redis_client is not None:
        try:
            await redis_client.enqueue_job(
                "sync_github_app_push_task",
                inst_id,
                repo_full_name,
                after_sha,
                branch,
            )
            return {"status": "queued", "repo": repo_full_name, "after": after_sha}
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning("Failed to enqueue push sync, falling back inline: %s", exc)

    from backend.worker import sync_github_app_push_task

    return await sync_github_app_push_task(
        {"redis": redis_client}, inst_id, repo_full_name, after_sha, branch
    )


def register_github_app_routes(
    app_router, get_tenant_id, _get_supabase=None, config=None
):
    """Register GitHub App OAuth, repo picker, indexing, and webhook routes."""

    @app_router.get("/api/v1/github-app/status")
    async def github_app_status(tenant_id: str = Depends(get_tenant_id)):
        cfg = _cfg(config)
        configured = gh_client.is_configured(cfg)
        installations: list[dict[str, Any]] = []
        sb = _get_supabase() if _get_supabase else None
        if sb and configured:
            rows = await asyncio.to_thread(gh_store.list_installations, sb, tenant_id)
            installations = [gh_store.public_installation_view(r) for r in rows]
        slug = (getattr(cfg, "github_app_slug", "") or "").strip("/")
        return {
            "configured": configured,
            "app_slug": slug,
            "manage_url": f"https://github.com/apps/{slug}/installations/new" if slug else "",
            "installations": installations,
        }

    @app_router.get("/api/v1/github-app/install/start")
    async def github_app_install_start(
        request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        cfg = _cfg(config)
        redis_client = _redis(request)
        if not redis_client:
            raise HTTPException(status_code=503, detail="Redis is unavailable")
        try:
            url = await gh_client.build_install_url(cfg, redis_client, tenant_id)
        except gh_client.GitHubAppError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {"authorization_url": url, "provider": "github_app"}

    @app_router.get("/api/v1/github-app/callback")
    async def github_app_callback(
        request: Request,
        code: str = "",
        installation_id: str = "",
        setup_action: str = "",
        state: str = "",
        error: str = "",
    ):
        cfg = _cfg(config)
        app_base = (cfg.public_app_url or "").rstrip("/")
        if error:
            return _oauth_callback_html(app_base, "github_app", "error", error)
        if setup_action == "request":
            return _oauth_callback_html(app_base, "github_app", "pending")
        if setup_action == "update" and (not code or not state):
            return _oauth_callback_html(app_base, "github_app", "connected")
        if not code or not state or not installation_id.isdigit():
            logger.warning(
                "GitHub App callback missing required parameters "
                "(has_code=%s has_state=%s valid_installation_id=%s setup_action=%s)",
                bool(code),
                bool(state),
                installation_id.isdigit(),
                setup_action or "none",
            )
            return _oauth_callback_html(
                app_base, "github_app", "error", "missing_params"
            )

        sb = _get_supabase() if _get_supabase else None
        redis_client = _redis(request)
        if not sb or not redis_client:
            return _oauth_callback_html(
                app_base, "github_app", "error", "storage_unavailable"
            )
        try:
            state_data = await gh_client.consume_install_state(redis_client, state)
            tenant_id = state_data["tenant_id"]
            token_bundle = await gh_client.exchange_user_oauth_code(cfg, code)
            user_token = str(token_bundle["access_token"])
            user_installs = await gh_client.list_user_installations(user_token)
            target_id = int(installation_id)
            matched = next(
                (i for i in user_installs if int(i.get("id") or 0) == target_id),
                None,
            )
            if matched is None:
                logger.warning(
                    "Rejected unowned GitHub App installation_id=%s for tenant=%s",
                    target_id,
                    tenant_id,
                )
                return _oauth_callback_html(
                    app_base, "github_app", "error", "access_denied"
                )
            account = matched.get("account") or {}
            await asyncio.to_thread(
                gh_store.upsert_installation,
                sb,
                tenant_id,
                installation_id=target_id,
                account_id=int(account.get("id") or 0),
                account_login=str(account.get("login") or "unknown"),
                account_type=str(account.get("type") or "User"),
                repository_selection=str(
                    matched.get("repository_selection") or "selected"
                ),
                permissions=matched.get("permissions") or {},
                user_tokens={
                    "access_token": user_token,
                    "refresh_token": token_bundle.get("refresh_token") or "",
                },
                user_token_expires_at=gh_store.token_expires_at_iso(
                    token_bundle.get("expires_in")
                ),
                status="active",
            )
        except gh_client.GitHubAppStateError as exc:
            logger.warning("GitHub App callback state rejected: %s", exc)
            return _oauth_callback_html(
                app_base, "github_app", "error", "state_expired"
            )
        except gh_client.GitHubAppConfigError as exc:
            logger.error("GitHub App callback configuration error: %s", exc)
            sentry_sdk.capture_exception(exc)
            return _oauth_callback_html(
                app_base, "github_app", "error", "invalid_app_config"
            )
        except gh_client.GitHubAppError as exc:
            logger.warning("GitHub App callback rejected: %s", exc)
            return _oauth_callback_html(app_base, "github_app", "error", "oauth_failed")
        except Exception as exc:
            logger.exception("Unexpected error in GitHub App callback")
            sentry_sdk.capture_exception(exc)
            return _oauth_callback_html(app_base, "github_app", "error", "oauth_failed")

        return _oauth_callback_html(app_base, "github_app", "connected")

    @app_router.get("/api/v1/github-app/repos")
    async def list_github_app_repos(
        request: Request,
        installation_id: int | None = None,
        q: str | None = None,
        tenant_id: str = Depends(get_tenant_id),
    ):
        sb = _require_supabase(_get_supabase)
        cfg = _cfg(config)
        redis_client = _redis(request)
        installations = await asyncio.to_thread(
            gh_store.list_installations, sb, tenant_id
        )
        if installation_id is not None:
            installations = [
                i
                for i in installations
                if int(i["installation_id"]) == int(installation_id)
            ]
        indexed_rows = await asyncio.to_thread(gh_store.list_repos, sb, tenant_id)
        indexed_by_name = {r["repo_full_name"]: r for r in indexed_rows}
        items = await _collect_installation_repos(
            cfg,
            sb,
            redis_client,
            installations,
            indexed_by_name,
            (q or "").strip().lower(),
        )
        return {"repos": items}

    @app_router.post("/api/v1/github-app/index")
    async def trigger_github_app_index(
        payload: GitHubAppIndexRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        sb = _require_supabase(_get_supabase)
        cfg = _cfg(config)
        redis_client = _redis(request)
        matched = await _verify_repo_access(
            cfg,
            sb,
            redis_client,
            tenant_id,
            payload.installation_id,
            payload.repo_full_name,
        )
        branch = payload.branch or matched.get("default_branch") or "main"
        await asyncio.to_thread(
            gh_store.upsert_repo,
            sb,
            tenant_id,
            installation_id=payload.installation_id,
            github_repo_id=int(matched.get("id") or 0),
            repo_full_name=payload.repo_full_name,
            default_branch=branch,
            is_private=bool(matched.get("private", True)),
            auto_sync_on_push=payload.auto_sync_on_push,
            index_status="indexing",
        )
        if cfg.worker_mode == "arq" and redis_client is not None:
            try:
                job = await redis_client.enqueue_job(
                    "index_github_app_repo_task",
                    tenant_id,
                    payload.installation_id,
                    payload.repo_full_name,
                    branch,
                )
                job_id = str(getattr(job, "job_id", "") or "")
                if job_id:
                    await redis_client.setex(
                        f"ghapp:job:{job_id}", _JOB_OWNER_TTL_SEC, tenant_id
                    )
                    await redis_client.setex(
                        f"ghapp:job_repo:{job_id}",
                        _JOB_OWNER_TTL_SEC,
                        payload.repo_full_name,
                    )
                return JSONResponse(
                    status_code=202,
                    content={
                        "status": "queued",
                        "job_id": job_id,
                        "repo_full_name": payload.repo_full_name,
                    },
                )
            except Exception as exc:
                sentry_sdk.capture_exception(exc)
                logger.warning(
                    "ARQ enqueue failed for GitHub App index, running inline: %s",
                    exc,
                )
        return await index_github_app_repo(
            cfg,
            sb,
            redis_client,
            tenant_id=tenant_id,
            installation_id=payload.installation_id,
            repo_full_name=payload.repo_full_name,
            branch=branch,
        )

    async def _read_job_snapshot(
        redis_client: Any, job_id: str, tenant_id: str
    ) -> dict[str, Any]:
        owner_raw = await redis_client.get(f"ghapp:job:{job_id}")
        owner = (
            owner_raw.decode("utf-8")
            if isinstance(owner_raw, bytes)
            else str(owner_raw or "")
        )
        if not owner or owner != tenant_id:
            raise HTTPException(status_code=404, detail="Job not found")
        try:
            from arq.jobs import Job

            job = Job(job_id, redis=redis_client)
            status = await job.status()
            info = await job.info()
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            raise HTTPException(status_code=404, detail="Job not found") from exc

        progress = None
        try:
            repo_raw = await redis_client.get(f"ghapp:job_repo:{job_id}")
            repo_name = (
                repo_raw.decode("utf-8")
                if isinstance(repo_raw, bytes)
                else str(repo_raw or "")
            )
            if repo_name:
                prog_raw = await redis_client.get(
                    f"ghapp:progress:{tenant_id}:{repo_name}"
                )
                if prog_raw:
                    prog_str = (
                        prog_raw.decode("utf-8")
                        if isinstance(prog_raw, bytes)
                        else str(prog_raw)
                    )
                    progress = json.loads(prog_str)
        except Exception:
            progress = None

        if status.value == "complete" and info is not None:
            if not getattr(info, "success", True):
                return {
                    "job_id": job_id,
                    "status": "failed",
                    "error": str(info.result)[:300],
                    "progress": progress,
                }
            result = info.result if isinstance(info.result, dict) else None
            return {
                "job_id": job_id,
                "status": "complete",
                "result": result,
                "progress": progress,
            }
        return {
            "job_id": job_id,
            "status": status.value,
            "result": None,
            "progress": progress,
        }

    @app_router.get("/api/v1/github-app/jobs/{job_id}")
    async def get_github_app_job(
        job_id: str,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        redis_client = _redis(request)
        if not redis_client:
            raise HTTPException(status_code=503, detail="Redis is unavailable")
        return await _read_job_snapshot(redis_client, job_id, tenant_id)

    @app_router.get("/api/v1/github-app/jobs/{job_id}/stream")
    async def stream_github_app_job(
        job_id: str,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        redis_client = _redis(request)
        if not redis_client:
            raise HTTPException(status_code=503, detail="Redis is unavailable")
        # Validate job ownership up front before opening SSE stream.
        initial = await _read_job_snapshot(redis_client, job_id, tenant_id)

        async def _event_stream():
            last_payload = ""
            snapshot = initial
            while True:
                encoded = json.dumps(snapshot)
                if encoded != last_payload:
                    last_payload = encoded
                    yield f"data: {encoded}\n\n"
                if snapshot.get("status") in ("complete", "failed"):
                    break
                if await request.is_disconnected():
                    break
                await asyncio.sleep(1.0)
                snapshot = await _read_job_snapshot(redis_client, job_id, tenant_id)

        return StreamingResponse(
            _event_stream(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )

    @app_router.delete("/api/v1/github-app/repos/{owner}/{repo}")
    async def disconnect_github_app_repo(
        owner: str, repo: str, tenant_id: str = Depends(get_tenant_id)
    ):
        sb = _require_supabase(_get_supabase)
        full_name = f"{owner}/{repo}"
        deleted = await asyncio.to_thread(gh_store.delete_repo, sb, tenant_id, full_name)
        if not deleted:
            raise HTTPException(status_code=404, detail="Repository not connected")
        await purge_github_app_repo(tenant_id, full_name)
        return {"status": "deleted", "repo_full_name": full_name}

    @app_router.post("/api/v1/github-app/webhook")
    async def github_app_webhook(request: Request):
        cfg = _cfg(config)
        body = await request.body()
        signature = request.headers.get("x-hub-signature-256") or ""
        _verify_webhook_signature(
            getattr(cfg, "github_app_webhook_secret", "") or "", body, signature
        )

        redis_client = _redis(request)
        delivery_id = request.headers.get("x-github-delivery") or ""
        if await _is_duplicate_delivery(redis_client, delivery_id):
            return JSONResponse(
                status_code=202,
                content={"status": "duplicate", "delivery_id": delivery_id},
            )

        try:
            payload = json.loads(body)
        except (ValueError, UnicodeDecodeError) as exc:
            raise HTTPException(status_code=400, detail="Invalid JSON payload") from exc

        sb = _get_supabase() if _get_supabase else None
        if not sb:
            return JSONResponse(
                status_code=202,
                content={"status": "ignored", "reason": "storage_unavailable"},
            )

        event = request.headers.get("x-github-event") or ""
        if event == "installation":
            result = await _handle_installation_event(cfg, sb, redis_client, payload)
        elif event == "installation_repositories":
            result = await _handle_installation_repos_event(
                cfg, sb, redis_client, payload
            )
        elif event == "repository" and payload.get("action") == "deleted":
            result = await _handle_repository_deleted_event(sb, payload)
        elif event == "push":
            result = await _handle_push_event(cfg, sb, redis_client, payload)
        else:
            result = {"status": "ignored", "event": event}

        return JSONResponse(status_code=202, content=result)
