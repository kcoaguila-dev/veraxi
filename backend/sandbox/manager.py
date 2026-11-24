"""Sandbox factory + session lifecycle manager.

Looks up the tenant's active sandbox config, decrypts its secrets via
:mod:`backend.security.token_vault` (through the sandbox store),
instantiates the right provider, tracks live sessions per
``(tenant, chat)``, and enforces idle cleanup based on
``idle_timeout_sec`` / ``last_active_at``.
"""

import asyncio
import hashlib
import hmac
import logging
from datetime import UTC, datetime, timedelta

import sentry_sdk

from backend.sandbox.base import (
    SandboxError,
    SandboxProvider,
    SandboxSessionInfo,
    normalize_settings,
)

logger = logging.getLogger(__name__)


class SandboxManager:
    """Factory and registry for sandbox providers and sessions."""

    def __init__(self, supabase=None, provider_factory=None, config=None, registry=None):
        self._supabase = supabase
        self._provider_factory = provider_factory  # seam for tests
        self._config = config
        self._registry = registry
        self._providers: dict[str, SandboxProvider] = {}
        self._sessions: dict[str, tuple[SandboxProvider, SandboxSessionInfo]] = {}
        self._chat_sessions: dict[tuple[str, str], str] = {}
        self._memory_configs: dict[str, dict] = {}
        self._approvals: dict[str, list[dict]] = {}
        self.approved_sessions: set[str] = set()

    # -- configuration --------------------------------------------------
    def set_supabase(self, supabase) -> None:
        if supabase is not None:
            self._supabase = supabase

    def set_tenant_config(self, tenant_id: str, settings: dict, secrets: dict | None = None) -> None:
        """Register an in-memory tenant config (tests / stateless mode)."""
        self._memory_configs[tenant_id] = {
            "settings": normalize_settings(settings, self._config),
            "secrets": dict(secrets or {}),
            "row": dict(settings or {}),
        }

    def load_tenant_config(self, tenant_id: str) -> tuple[dict, dict, dict | None]:
        """Return ``(settings, secrets, raw_row)`` for a tenant."""
        if tenant_id in self._memory_configs:
            entry = self._memory_configs[tenant_id]
            return entry["settings"], entry["secrets"], entry["row"]
        if self._supabase is not None:
            from backend.services import sandbox_store as store

            row = store.get_config(self._supabase, tenant_id)
            if row is not None:
                return normalize_settings(row, self._config), store.decrypt_row_secrets(row), row
        return normalize_settings(None, self._config), {}, None

    def create_provider(self, settings: dict, secrets: dict) -> SandboxProvider:
        """Instantiate the provider named by ``settings['provider']``."""
        if self._provider_factory is not None:
            return self._provider_factory(settings, secrets)
        provider = str(settings.get("provider") or "disabled")
        if provider == "modal":
            from backend.sandbox.modal_provider import ModalProvider

            return ModalProvider(settings, secrets)
        if provider == "e2b":
            from backend.sandbox.e2b_provider import E2BProvider

            return E2BProvider(settings, secrets)
        if provider == "remote_mcp":
            from backend.sandbox.remote_mcp_provider import RemoteMcpProvider

            return RemoteMcpProvider(settings, secrets)
        if provider == "local_runner":
            from backend.sandbox.ws_runner_provider import WsRunnerProvider

            return WsRunnerProvider(settings, secrets, registry=self._registry)
        raise SandboxError(f"Sandbox provider {provider!r} is disabled or unknown")

    # -- runner token ---------------------------------------------------
    def validate_runner_token(self, tenant_id: str, token: str) -> bool:
        """Validate a runner token against the tenant's stored secrets.

        Accepts the decrypted ``runner_token`` value, or a stored
        ``runner_token_hash`` (SHA-256 hex) so the raw token need not
        be recoverable server-side.
        """
        if not tenant_id or not token:
            return False
        try:
            _settings, secrets, _row = self.load_tenant_config(tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            return False
        stored = secrets.get("runner_token")
        if stored and hmac.compare_digest(str(stored), token):
            return True
        stored_hash = secrets.get("runner_token_hash")
        if stored_hash:
            digest = hashlib.sha256(token.encode()).hexdigest()
            return hmac.compare_digest(str(stored_hash), digest)
        return False

    # -- sessions ---------------------------------------------------------
    async def start_session(
        self, tenant_id: str, chat_id: str | None = None,
        project_id: str | None = None, repo_url: str | None = None,
    ) -> SandboxSessionInfo:
        await self.cleanup_idle_sessions()
        settings, secrets, row = self.load_tenant_config(tenant_id)
        if str(settings.get("provider") or "disabled") == "disabled" and self._provider_factory is None:
            raise SandboxError("Sandboxes are disabled for this tenant")
        provider = self.create_provider(settings, secrets)
        info = await provider.start_session(tenant_id, repo_url=repo_url)
        info.chat_id = chat_id
        info.project_id = project_id
        info.config_id = (row or {}).get("id") or settings.get("id")
        info.provider = str(settings.get("provider") or info.provider)
        self._providers[info.session_id] = provider
        self._sessions[info.session_id] = (provider, info)
        if chat_id:
            self._chat_sessions[(tenant_id, chat_id)] = info.session_id
        self._persist_session(info)
        return info

    def _persist_session(self, info: SandboxSessionInfo) -> None:
        if self._supabase is None:
            return
        try:
            from backend.services import sandbox_store as store

            store.create_session(self._supabase, info.tenant_id, {
                "id": info.session_id,
                "config_id": info.config_id,
                "project_id": info.project_id,
                "chat_id": info.chat_id,
                "external_sandbox_id": info.external_sandbox_id,
                "status": info.status,
                "git_branch": info.git_branch,
                "last_active_at": info.last_active_at.isoformat(),
            })
        except Exception as e:  # Persistence must not kill a live session.
            sentry_sdk.capture_exception(e)
            logger.warning("Failed to persist sandbox session %s: %s", info.session_id, e)

    def _update_session_row(self, info: SandboxSessionInfo) -> None:
        if self._supabase is None:
            return
        try:
            from backend.services import sandbox_store as store

            store.update_session(self._supabase, info.tenant_id, info.session_id, {
                "status": info.status,
                "last_active_at": info.last_active_at.isoformat(),
            })
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.warning("Failed to update sandbox session %s: %s", info.session_id, e)

    async def get_or_create_session(
        self, tenant_id: str, chat_id: str | None = None,
        project_id: str | None = None, repo_url: str | None = None,
    ) -> SandboxSessionInfo:
        """Return the live session for ``(tenant, chat)`` or start one."""
        key = (tenant_id, chat_id or "")
        existing_id = self._chat_sessions.get(key)
        if existing_id and existing_id in self._sessions:
            _provider, info = self._sessions[existing_id]
            if info.status == "running":
                info.touch()
                return info
        return await self.start_session(
            tenant_id, chat_id=chat_id, project_id=project_id, repo_url=repo_url
        )

    def get_session(self, session_id: str) -> tuple[SandboxProvider, SandboxSessionInfo] | None:
        return self._sessions.get(session_id)

    def session_id_for_chat(self, tenant_id: str, chat_id: str | None) -> str | None:
        """Return the live session id bound to ``(tenant, chat)``, if any."""
        if not chat_id:
            return None
        session_id = self._chat_sessions.get((tenant_id, chat_id))
        if session_id and session_id in self._sessions:
            return session_id
        for _provider, info in self._sessions.values():
            if info.tenant_id == tenant_id and info.chat_id == chat_id:
                return info.session_id
        return None

    def provider_for(self, session_id: str) -> SandboxProvider | None:
        entry = self._sessions.get(session_id)
        return entry[0] if entry else None

    def list_session_infos(self, tenant_id: str) -> list[SandboxSessionInfo]:
        return [info for _p, info in self._sessions.values() if info.tenant_id == tenant_id]

    async def pause_session(self, session_id: str) -> SandboxSessionInfo:
        entry = self._sessions.get(session_id)
        if entry is None:
            raise SandboxError(f"Unknown sandbox session {session_id}")
        provider, info = entry
        await provider.pause_session(session_id)
        info.status = "paused"
        self._update_session_row(info)
        return info

    async def resume_session(self, session_id: str) -> SandboxSessionInfo:
        entry = self._sessions.get(session_id)
        if entry is None:
            raise SandboxError(f"Unknown sandbox session {session_id}")
        provider, info = entry
        await provider.resume_session(session_id)
        info.status = "running"
        info.touch()
        self._update_session_row(info)
        return info

    async def stop_session(self, session_id: str) -> bool:
        entry = self._sessions.pop(session_id, None)
        self._providers.pop(session_id, None)
        if entry is None:
            return False
        provider, info = entry
        self._chat_sessions = {
            k: v for k, v in self._chat_sessions.items() if v != session_id
        }
        try:
            await provider.stop_session(session_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.warning("Provider stop failed for %s: %s", session_id, e)
        info.status = "stopped"
        self._update_session_row(info)
        return True

    async def cleanup_idle_sessions(self, now: datetime | None = None) -> list[str]:
        """Stop sessions idle longer than their config's idle timeout."""
        now = now or datetime.now(UTC)
        stopped: list[str] = []
        for session_id, (_provider, info) in list(self._sessions.items()):
            if info.status != "running":
                continue
            try:
                settings, _secrets, _row = self.load_tenant_config(info.tenant_id)
                idle = int(settings.get("idle_timeout_sec") or 900)
            except Exception as e:
                sentry_sdk.capture_exception(e)
                idle = 900
            last = info.last_active_at
            if last.tzinfo is None:
                last = last.replace(tzinfo=UTC)
            if now - last > timedelta(seconds=idle):
                await self.stop_session(session_id)
                stopped.append(session_id)
        return stopped

    # -- approvals --------------------------------------------------------
    def record_approval_request(self, session_id: str, payload: dict) -> None:
        self._approvals.setdefault(session_id, []).append(payload)

    def approve_session(self, session_id: str, approved: bool, tool_name: str | None = None) -> dict:
        """Resolve pending approvals for a session (approve endpoint)."""
        pending = self._approvals.pop(session_id, [])
        if approved:
            self.approved_sessions.add(session_id)
        return {
            "session_id": session_id,
            "approved": approved,
            "tool_name": tool_name,
            "resolved": len(pending),
            "pending": pending,
        }


_default_manager: SandboxManager | None = None


def get_default_manager() -> SandboxManager:
    """Process-wide manager, lazily bound to the gateway Supabase client."""
    global _default_manager
    if _default_manager is None:
        supabase = None
        try:
            from backend.api_gateway import _get_supabase

            supabase = _get_supabase()
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.debug("Default sandbox manager without Supabase: %s", e)
        _default_manager = SandboxManager(supabase=supabase)
    else:
        try:
            from backend.api_gateway import _get_supabase

            _default_manager.set_supabase(_get_supabase())
        except Exception as e:
            logger.debug("Sandbox manager Supabase refresh skipped: %s", e)
    return _default_manager


def set_default_manager(manager: SandboxManager | None) -> None:
    """Replace the process-wide manager (test seam)."""
    global _default_manager
    _default_manager = manager


async def _gather_exec(provider, session_id: str, cmd: str, cwd=None, timeout_sec: int = 120):
    """Collect exec events into (stdout, stderr, exit_code, events)."""
    stdout_parts: list[str] = []
    stderr_parts: list[str] = []
    events: list[dict] = []
    exit_code: int | None = None
    async for event in provider.exec_command(session_id, cmd, cwd=cwd, timeout_sec=timeout_sec):
        events.append(event.to_dict())
        if event.kind == "stdout":
            stdout_parts.append(event.data)
        elif event.kind == "stderr":
            stderr_parts.append(event.data)
        elif event.kind == "exit":
            exit_code = event.exit_code
    return "".join(stdout_parts), "".join(stderr_parts), exit_code, events


# Re-exported for callers that schedule periodic cleanup.
cleanup_task = None


async def periodic_idle_cleanup(manager: SandboxManager, interval_sec: int = 60):  # pragma: no cover
    while True:
        await asyncio.sleep(interval_sec)
        await manager.cleanup_idle_sessions()
