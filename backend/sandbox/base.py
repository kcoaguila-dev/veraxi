"""Sandbox provider abstraction for hybrid agentic coding.

A provider boots an isolated execution environment for one tenant,
runs commands / file operations inside it, and tears it down. Concrete
providers: Modal and E2B (cloud serverless), a remote MCP server on
user-owned hardware, and the outbound-WebSocket ``veraxi-runner``.

Tenant credentials are always passed in per session from decrypted
secrets (see :mod:`backend.security.token_vault`); providers never read
global environment variables for tenant tokens and never place raw
secrets inside the sandbox environment.
"""

import logging
import uuid
from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from datetime import UTC, datetime

logger = logging.getLogger(__name__)

IMAGE_PRESETS: dict[str, dict[str, str]] = {
    "python": {"modal": "python", "e2b": "base", "docker": "python:3.12-slim"},
    "node": {"modal": "node", "e2b": "base", "docker": "node:22-slim"},
    "flutter": {"modal": "flutter", "e2b": "base", "docker": "ghcr.io/cirruslabs/flutter:stable"},
    "polyglot": {"modal": "polyglot", "e2b": "base", "docker": "python:3.12-slim"},
}

DEFAULT_ALLOWED_DOMAINS = [
    "pypi.org", "files.pythonhosted.org", "registry.npmjs.org",
    "pub.dev", "github.com",
]


def resolve_image(preset: str | None, provider: str) -> str:
    """Map a base-image preset name to a provider-specific image ref."""
    entry = IMAGE_PRESETS.get((preset or "polyglot").lower())
    if entry is None:
        # Unknown presets are treated as an explicit image reference.
        return str(preset)
    return entry.get(provider, entry["docker"])


def default_settings(config: object | None = None) -> dict:
    """Build a sandbox settings dict from global Config defaults."""
    cfg = config
    if cfg is None:
        try:
            from backend.config import get_config

            cfg = get_config()
        except Exception:  # Config unavailable (unit tests): use spec defaults.
            cfg = None
    return {
        "provider": getattr(cfg, "sandbox_default_provider", "disabled") or "disabled",
        "display_name": "",
        "base_image": getattr(cfg, "sandbox_default_base_image", "polyglot") or "polyglot",
        "cpu_cores": int(getattr(cfg, "sandbox_default_cpu_cores", 2) or 2),
        "memory_mb": int(getattr(cfg, "sandbox_default_memory_mb", 4096) or 4096),
        "disk_gb": int(getattr(cfg, "sandbox_default_disk_gb", 10) or 10),
        "idle_timeout_sec": int(getattr(cfg, "sandbox_idle_timeout_sec", 900) or 900),
        "max_session_sec": int(getattr(cfg, "sandbox_max_session_sec", 3600) or 3600),
        "autonomy_mode": getattr(cfg, "sandbox_default_autonomy_mode", "auto_read_test") or "auto_read_test",
        "egress_mode": getattr(cfg, "sandbox_default_egress_mode", "allowlist") or "allowlist",
        "allowed_domains": list(DEFAULT_ALLOWED_DOMAINS),
        "isolate_git_branch": True,
        "config": {},
    }


def normalize_settings(row: dict | None, config: object | None = None) -> dict:
    """Merge a stored config row over the global defaults."""
    settings = default_settings(config)
    if row:
        for key in list(settings.keys()):
            if row.get(key) is not None:
                settings[key] = row[key]
        if row.get("id"):
            settings["id"] = row["id"]
        if row.get("tenant_id"):
            settings["tenant_id"] = row["tenant_id"]
    if not isinstance(settings.get("config"), dict):
        settings["config"] = {}
    if not isinstance(settings.get("allowed_domains"), list):
        settings["allowed_domains"] = list(DEFAULT_ALLOWED_DOMAINS)
    return settings


@dataclass
class SandboxSessionInfo:
    """Identity and lifecycle state of one sandbox session."""

    session_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    tenant_id: str = ""
    provider: str = ""
    status: str = "starting"  # starting | running | paused | stopped | error
    external_sandbox_id: str = ""
    git_branch: str = ""
    chat_id: str | None = None
    project_id: str | None = None
    config_id: str | None = None
    created_at: datetime = field(default_factory=lambda: datetime.now(UTC))
    last_active_at: datetime = field(default_factory=lambda: datetime.now(UTC))

    def touch(self) -> None:
        self.last_active_at = datetime.now(UTC)

    def public_view(self) -> dict:
        return {
            "id": self.session_id,
            "tenant_id": self.tenant_id,
            "provider": self.provider,
            "status": self.status,
            "external_sandbox_id": self.external_sandbox_id,
            "git_branch": self.git_branch,
            "chat_id": self.chat_id,
            "project_id": self.project_id,
            "config_id": self.config_id,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "last_active_at": self.last_active_at.isoformat() if self.last_active_at else None,
        }


@dataclass
class ExecEvent:
    """One streamed chunk (or the terminal exit event) of an exec."""

    kind: str  # 'stdout' | 'stderr' | 'exit'
    data: str = ""
    exit_code: int | None = None

    def to_dict(self) -> dict:
        out: dict = {"type": self.kind, "data": self.data}
        if self.kind == "exit":
            out["exit_code"] = self.exit_code
        return out


class SandboxError(RuntimeError):
    """Raised for sandbox lifecycle / execution failures."""


class SandboxProvider(ABC):
    """Abstract sandbox backend. ``settings`` is a normalized dict and
    ``secrets`` the tenant's decrypted secrets (server-side only)."""

    provider_name: str = "base"

    def __init__(self, settings: dict, secrets: dict | None = None):
        self.settings = settings or {}
        self._secrets = secrets or {}

    @abstractmethod
    async def start_session(
        self, tenant_id: str, repo_url: str | None = None
    ) -> SandboxSessionInfo:
        """Boot a sandbox and return its session info."""

    @abstractmethod
    def exec_command(
        self, session_id: str, cmd: str, cwd: str | None = None,
        timeout_sec: int = 120,
    ) -> AsyncIterator[ExecEvent]:
        """Stream stdout/stderr chunks and a final exit event."""

    @abstractmethod
    async def read_file(self, session_id: str, path: str) -> str:
        """Read a file inside the sandbox."""

    @abstractmethod
    async def write_file(self, session_id: str, path: str, content: str) -> None:
        """Write a file inside the sandbox."""

    @abstractmethod
    async def get_diff(self, session_id: str) -> str:
        """Return the current git diff inside the sandbox."""

    @abstractmethod
    async def stop_session(self, session_id: str) -> None:
        """Terminate a sandbox session."""

    async def pause_session(self, session_id: str) -> None:
        raise SandboxError(f"Provider {self.provider_name} does not support pause")

    async def resume_session(self, session_id: str) -> None:
        raise SandboxError(f"Provider {self.provider_name} does not support resume")

    # -- shared helpers -------------------------------------------------
    def _branch_for(self, tenant_id: str) -> str:
        return f"veraxi/sandbox-{uuid.uuid4().hex[:8]}"

    async def _maybe_clone_repo(
        self, session_id: str, repo_url: str | None
    ) -> str:
        """Clone ``repo_url`` onto an isolated branch; returns branch."""
        if not repo_url:
            return ""
        branch = self._branch_for(session_id) if self.settings.get("isolate_git_branch", True) else ""
        clone_cmd = f"git clone {repo_url} repo"
        async for _event in self.exec_command(session_id, clone_cmd, timeout_sec=300):
            pass
        if branch:
            async for _event in self.exec_command(
                session_id, f"git checkout -b {branch}", cwd="repo", timeout_sec=60
            ):
                pass
        return branch
