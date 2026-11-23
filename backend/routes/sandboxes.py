"""Hybrid sandbox endpoints (cloud / remote MCP / local runner).

Follows the ``routes/integrations.py`` registration pattern: routes
are registered with injected auth dependencies and reach Supabase
through the gateway's ``_get_supabase``. When Supabase is unavailable
(stateless local mode) the config/session endpoints return 501.

Secrets are never returned: config responses go through
:func:`backend.services.sandbox_store.public_view`, which exposes
only ``has_secrets``. The runner WebSocket authenticates with the
per-tenant runner token stored (Fernet-encrypted) in the tenant's
sandbox config secrets.
"""

import asyncio
import logging
import time

import sentry_sdk
from fastapi import Depends, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from backend.sandbox.base import normalize_settings
from backend.sandbox.git_diff import (
    GitError,
    NotGitRepoError,
    PathValidationError,
    collect_session_diff,
    get_repo_root,
    git_add_paths,
    git_commit,
    git_revert_paths,
    validate_repo_paths,
)
from backend.sandbox.manager import SandboxManager
from backend.sandbox.ws_runner_provider import GLOBAL_REGISTRY, WsRunnerProvider
from backend.services import sandbox_store as store

logger = logging.getLogger(__name__)

_manager_override: SandboxManager | None = None


def set_sandbox_manager(manager: SandboxManager | None) -> None:
    """Inject the SandboxManager used by the routes (test seam)."""
    global _manager_override
    _manager_override = manager


def _require_supabase(_get_supabase):
    sb = _get_supabase()
    if not sb:
        raise HTTPException(
            status_code=501,
            detail="Sandboxes are not supported in stateless local mode",
        )
    return sb


class SandboxConfigPutRequest(BaseModel):
    provider: str | None = None
    display_name: str | None = None
    base_image: str | None = None
    cpu_cores: int | None = None
    memory_mb: int | None = None
    disk_gb: int | None = None
    idle_timeout_sec: int | None = None
    max_session_sec: int | None = None
    autonomy_mode: str | None = None
    egress_mode: str | None = None
    allowed_domains: list[str] | None = None
    isolate_git_branch: bool | None = None
    config: dict | None = None
    is_active: bool | None = None
    secrets: dict | None = None


class SandboxTestRequest(BaseModel):
    repo_url: str | None = None


class SandboxApproveRequest(BaseModel):
    approve: bool = True
    tool_name: str | None = None


class SandboxPathsRequest(BaseModel):
    paths: list[str] = []


class SandboxCommitRequest(BaseModel):
    message: str = ""


def register_sandbox_routes(app_router, get_tenant_id, _get_supabase, config=None, manager=None):
    """Register all sandbox routes with injected auth dependencies."""
    injected_manager = manager

    def _manager(sb=None) -> SandboxManager:
        mgr = injected_manager or _manager_override
        if mgr is not None:
            if sb is not None:
                mgr.set_supabase(sb)
            return mgr
        return SandboxManager(supabase=sb, config=config)

    @app_router.get("/api/v1/sandboxes/config")
    async def get_sandbox_config(tenant_id: str = Depends(get_tenant_id)):
        """Return the tenant's sandbox config (secrets masked)."""
        sb = _require_supabase(_get_supabase)
        try:
            row = await asyncio.to_thread(store.get_config, sb, tenant_id)
            if row is None:
                defaults = normalize_settings(None, config)
                defaults["tenant_id"] = tenant_id
                return store.public_view(defaults)
            return store.public_view(row)
        except HTTPException:
            raise
        except Exception as e:
            store.report_error(e)
            raise HTTPException(status_code=500, detail="Failed to load sandbox config") from e

    @app_router.put("/api/v1/sandboxes/config")
    async def put_sandbox_config(
        payload: SandboxConfigPutRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Create/update the tenant's sandbox config.

        Provided ``secrets`` are merged over the stored set and
        Fernet-encrypted; they are never returned.
        """
        sb = _require_supabase(_get_supabase)
        try:
            data = payload.model_dump(exclude={"secrets"}, exclude_none=True)
            try:
                store.validate_config_fields(data)
            except ValueError as e:
                raise HTTPException(status_code=400, detail=str(e)) from e
            merged_secrets = None
            if payload.secrets is not None:
                existing = await asyncio.to_thread(store.get_config, sb, tenant_id)
                current = store.decrypt_row_secrets(existing) if existing else {}
                merged_secrets = {**current, **payload.secrets}
            row = await asyncio.to_thread(
                store.upsert_config, sb, tenant_id, data, merged_secrets
            )
            return store.public_view(row)
        except HTTPException:
            raise
        except Exception as e:
            store.report_error(e)
            raise HTTPException(status_code=500, detail="Failed to save sandbox config") from e

    @app_router.post("/api/v1/sandboxes/test")
    async def test_sandbox(
        payload: SandboxTestRequest | None = None,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Boot a sandbox, run a smoke command, report latency, tear down."""
        sb = _get_supabase()
        mgr = _manager(sb)
        started = time.monotonic()
        session_id = None
        try:
            info = await mgr.start_session(
                tenant_id, repo_url=(payload.repo_url if payload else None)
            )
            session_id = info.session_id
            provider = mgr.provider_for(session_id)
            output_parts: list[str] = []
            exit_code = None
            async for event in provider.exec_command(
                session_id, "uname -a && git --version", timeout_sec=60
            ):
                if event.kind in ("stdout", "stderr"):
                    output_parts.append(event.data)
                elif event.kind == "exit":
                    exit_code = event.exit_code
            latency_ms = int((time.monotonic() - started) * 1000)
            return {
                "status": "running" if exit_code in (0, None) else "error",
                "provider": info.provider,
                "session_id": session_id,
                "latency_ms": latency_ms,
                "output": "".join(output_parts),
                "exit_code": exit_code,
            }
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=502, detail=f"Sandbox test failed: {e}") from e
        finally:
            if session_id:
                try:
                    await mgr.stop_session(session_id)
                except Exception as e:  # Teardown must not mask the result.
                    sentry_sdk.capture_exception(e)
                    logger.warning("Sandbox test teardown failed: %s", e)

    @app_router.get("/api/v1/sandboxes/sessions")
    async def list_sandbox_sessions(tenant_id: str = Depends(get_tenant_id)):
        """List the tenant's sandbox sessions."""
        sb = _get_supabase()
        mgr = _manager(sb)
        try:
            sessions: dict[str, dict] = {}
            if sb is not None:
                rows = await asyncio.to_thread(store.list_sessions, sb, tenant_id)
                for row in rows:
                    sessions[str(row.get("id"))] = store.session_public_view(row)
            for info in mgr.list_session_infos(tenant_id):
                sessions[info.session_id] = info.public_view()
            return {"sessions": list(sessions.values())}
        except Exception as e:
            store.report_error(e)
            raise HTTPException(status_code=500, detail="Failed to list sandbox sessions") from e

    @app_router.post("/api/v1/sandboxes/sessions/{session_id}/pause")
    async def pause_sandbox_session(
        session_id: str, tenant_id: str = Depends(get_tenant_id)
    ):
        sb = _get_supabase()
        mgr = _manager(sb)
        entry = mgr.get_session(session_id)
        row = None
        if sb is not None:
            row = await asyncio.to_thread(store.get_session, sb, tenant_id, session_id)
        if entry is None and row is None:
            raise HTTPException(status_code=404, detail="Sandbox session not found")
        try:
            if entry is not None:
                info = await mgr.pause_session(session_id)
                return info.public_view()
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=502, detail=f"Failed to pause sandbox: {e}") from e
        await asyncio.to_thread(
            store.update_session, sb, tenant_id, session_id, {"status": "paused"}
        )
        row = await asyncio.to_thread(store.get_session, sb, tenant_id, session_id)
        return store.session_public_view(row or {})

    @app_router.delete("/api/v1/sandboxes/sessions/{session_id}")
    async def delete_sandbox_session(
        session_id: str, tenant_id: str = Depends(get_tenant_id)
    ):
        sb = _get_supabase()
        mgr = _manager(sb)
        entry = mgr.get_session(session_id)
        row = None
        if sb is not None:
            row = await asyncio.to_thread(store.get_session, sb, tenant_id, session_id)
        if entry is None and row is None and sb is not None:
            raise HTTPException(status_code=404, detail="Sandbox session not found")
        if entry is not None:
            await mgr.stop_session(session_id)
        if sb is not None and row is not None:
            await asyncio.to_thread(store.delete_session, sb, tenant_id, session_id)
        return {"status": "stopped", "session_id": session_id}

    @app_router.post("/api/v1/sandboxes/sessions/{session_id}/approve")
    async def approve_sandbox_session(
        session_id: str,
        payload: SandboxApproveRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Resolve a pending ``approval_required`` sandbox tool call."""
        sb = _get_supabase()
        mgr = _manager(sb)
        entry = mgr.get_session(session_id)
        row = None
        if sb is not None:
            row = await asyncio.to_thread(store.get_session, sb, tenant_id, session_id)
        if entry is None and row is None and sb is not None:
            raise HTTPException(status_code=404, detail="Sandbox session not found")
        result = mgr.approve_session(session_id, payload.approve, payload.tool_name)
        return {"status": "approved" if payload.approve else "rejected", **result}

    def _session_provider(mgr, tenant_id: str, session_id: str):
        """Resolve a live session's provider, fail-closed on tenant mismatch."""
        entry = mgr.get_session(session_id)
        if entry is None:
            raise HTTPException(status_code=404, detail="Sandbox session not found")
        provider, info = entry
        if getattr(info, "tenant_id", None) not in (None, "", tenant_id):
            raise HTTPException(status_code=404, detail="Sandbox session not found")
        return provider

    async def _validated_paths(mgr, tenant_id, session_id, paths):
        provider = _session_provider(mgr, tenant_id, session_id)
        try:
            root = await get_repo_root(provider, session_id)
        except NotGitRepoError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        try:
            return provider, validate_repo_paths(paths, root)
        except PathValidationError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

    @app_router.get("/api/v1/sandboxes/sessions/{session_id}/diff")
    async def get_sandbox_diff(
        session_id: str,
        turn_id: str = "",
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Read-only git diff summary for one session (Code Mode Phase 2)."""
        sb = _get_supabase()
        mgr = _manager(sb)
        provider = _session_provider(mgr, tenant_id, session_id)
        try:
            return await collect_session_diff(provider, session_id, turn_id=turn_id)
        except NotGitRepoError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        except GitError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=502, detail=f"Sandbox diff failed: {e}") from e

    @app_router.post("/api/v1/sandboxes/sessions/{session_id}/files/accept")
    async def accept_sandbox_files(
        session_id: str,
        payload: SandboxPathsRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Stage the given files (``git add -- <path>`` per file)."""
        sb = _get_supabase()
        mgr = _manager(sb)
        provider, rel_paths = await _validated_paths(
            mgr, tenant_id, session_id, payload.paths
        )
        try:
            await git_add_paths(provider, session_id, rel_paths)
        except GitError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        return {"session_id": session_id, "accepted": rel_paths}

    @app_router.post("/api/v1/sandboxes/sessions/{session_id}/files/revert")
    async def revert_sandbox_files(
        session_id: str,
        payload: SandboxPathsRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Revert the given files: checkout tracked, remove untracked."""
        sb = _get_supabase()
        mgr = _manager(sb)
        provider, rel_paths = await _validated_paths(
            mgr, tenant_id, session_id, payload.paths
        )
        try:
            await git_revert_paths(provider, session_id, rel_paths)
        except GitError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        return {"session_id": session_id, "reverted": rel_paths}

    @app_router.post("/api/v1/sandboxes/sessions/{session_id}/commit")
    async def commit_sandbox_files(
        session_id: str,
        payload: SandboxCommitRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Commit staged files with the user's message. NEVER pushes."""
        if not payload.message or not payload.message.strip():
            raise HTTPException(status_code=400, detail="Commit message must not be empty")
        sb = _get_supabase()
        mgr = _manager(sb)
        provider = _session_provider(mgr, tenant_id, session_id)
        try:
            await get_repo_root(provider, session_id)
        except NotGitRepoError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        try:
            await git_commit(provider, session_id, payload.message.strip())
        except GitError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        return {"session_id": session_id, "committed": True, "message": payload.message.strip()}

    @app_router.websocket("/api/v1/sandboxes/runner/ws")
    async def runner_websocket(websocket: WebSocket):
        """Outbound runner tunnel: one socket per tenant, token-auth'd."""
        tenant_id = websocket.query_params.get("tenant_id") or ""
        token = websocket.query_params.get("token") or ""
        if not token:
            auth = websocket.headers.get("authorization") or ""
            if auth.lower().startswith("bearer "):
                token = auth[7:].strip()
        sb = _get_supabase()
        mgr = _manager(sb)
        if not tenant_id or not mgr.validate_runner_token(tenant_id, token):
            await websocket.close(code=4401)
            return
        await websocket.accept()
        provider = WsRunnerProvider({}, {}, registry=GLOBAL_REGISTRY)
        GLOBAL_REGISTRY.register(tenant_id, websocket)
        logger.info("veraxi-runner connected for tenant %s", tenant_id)
        try:
            while True:
                raw = await websocket.receive_text()
                await provider.handle_message(tenant_id, raw)
        except WebSocketDisconnect:
            logger.info("veraxi-runner disconnected for tenant %s", tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.warning("Runner websocket error for tenant %s: %s", tenant_id, e)
        finally:
            GLOBAL_REGISTRY.unregister(tenant_id, websocket)
