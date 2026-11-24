"""ACP Session Broker — selects local stdio or runner WebSocket transport."""

from __future__ import annotations

import os
import subprocess
from collections.abc import AsyncGenerator
from typing import Any

from backend.acp.driver import AcpDriverError, LocalAcpDriver
from backend.acp.protocol import build_friendly_acp_error
from backend.acp.runner_transport import RunnerAcpTransport
from backend.acp.usage_reader import read_local_usage_summary
from backend.config import get_config

DEFAULT_ANTIGRAVITY_MODELS: list[str] = [
    "gemini-4-neon-high",
    "gemini-4-neon-xhigh",
    "gemini-4-neon-medium",
    "gemini-4-neon-low",
    "gemini-4-carbon-high",
    "gemini-4-carbon-medium",
    "gemini-4-carbon-low",
    "gemini-4-argon-high",
    "gemini-4-argon-medium",
    "gemini-4-argon-low",
    "gemini-4-hydrogen-high",
    "gemini-4-hydrogen-xhigh",
    "gemini-4-hydrogen-medium",
    "gemini-4-hydrogen-low",
    "gemini-pro-orchestrator-neon",
    "gemini-pro-orchestrator",
    "gemini-pro-orchestrator-argon",
    "gemini-3.8-flash-high",
    "gemini-3.8-flash-medium",
    "gemini-3.8-flash-low",
    "claude-opus-5-5-high",
    "claude-opus-5-5-medium",
    "claude-opus-5-5-low",
    "claude-sonnet-5-5-high",
    "claude-sonnet-5-5-medium",
    "claude-sonnet-5-5-low",
    "gpt-oss-120b-medium",
]


class AcpSessionBroker:
    """Unified entry point for external ACP agent sessions."""

    def __init__(
        self,
        local_driver: LocalAcpDriver | None = None,
        runner_transport: RunnerAcpTransport | None = None,
    ):
        cfg = get_config()
        self.local_driver = local_driver or LocalAcpDriver(
            binary=cfg.antigravity_acp_bin,
            idle_timeout_sec=cfg.acp_idle_timeout_sec,
            max_sessions_per_tenant=cfg.acp_max_sessions_per_tenant,
        )
        self.runner_transport = runner_transport or RunnerAcpTransport()
        self._session_tenants: dict[str, str] = {}

    def get_status(self, tenant_id: str) -> dict[str, Any]:
        """Report ACP availability, active transport, and honest local usage summary."""
        cfg = get_config()
        runner_connected = self.runner_transport.is_connected(tenant_id)
        local_ok, local_bin = self.local_driver.is_available()
        usage = read_local_usage_summary(cfg.antigravity_data_dir)

        if runner_connected:
            transport = "veraxi_runner"
            available = True
        elif cfg.acp_enabled and local_ok:
            transport = "local_stdio"
            available = True
        else:
            transport = "unavailable"
            available = False

        return {
            "available": available,
            "acp_enabled": cfg.acp_enabled,
            "transport": transport,
            "binary": local_bin or cfg.antigravity_acp_bin,
            "runner_connected": runner_connected,
            "models": self._list_local_models(local_bin) if local_ok else list(DEFAULT_ANTIGRAVITY_MODELS),
            "usage": usage,
        }

    def _list_local_models(self, binary: str | None) -> list[str]:
        if not binary:
            return list(DEFAULT_ANTIGRAVITY_MODELS)
        try:
            proc = subprocess.run(
                [binary, "models"],
                capture_output=True,
                text=True,
                timeout=4.0,
                check=False,
            )
            if proc.returncode != 0 or not proc.stdout:
                return list(DEFAULT_ANTIGRAVITY_MODELS)
            parsed: list[str] = []
            for line in proc.stdout.splitlines():
                token = line.strip().split(" ", 1)[0]
                if token and not token.startswith(("⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏")):
                    parsed.append(token)
            return parsed or list(DEFAULT_ANTIGRAVITY_MODELS)
        except (OSError, subprocess.SubprocessError):
            return list(DEFAULT_ANTIGRAVITY_MODELS)

    def _build_veraxi_mcp_servers(
        self, tenant_id: str, attach_veraxi_mcp: bool
    ) -> list[dict[str, Any]]:
        if not attach_veraxi_mcp:
            return []
        cfg = get_config()
        base = cfg.internal_api_url.rstrip("/").removesuffix("/api")
        return [
            {
                "name": "veraxi",
                "type": "http",
                "url": f"{base}/mcp",
                "headers": {"x-tenant-id": tenant_id},
            }
        ]

    async def stream_prompt(
        self,
        tenant_id: str,
        thread_id: str,
        prompt_text: str,
        cwd: str | None = None,
        attach_veraxi_mcp: bool = True,
        model: str | None = None,
    ) -> AsyncGenerator[dict[str, Any], None]:
        """Stream a single interactive prompt turn over the active ACP transport."""
        cfg = get_config()
        effective_cwd = cwd or os.getcwd()
        mcp_servers = self._build_veraxi_mcp_servers(tenant_id, attach_veraxi_mcp)

        if self.runner_transport.is_connected(tenant_id):
            async for evt in self.runner_transport.stream_prompt(
                tenant_id=tenant_id,
                thread_id=thread_id,
                prompt_text=prompt_text,
                cwd=effective_cwd,
                mcp_servers=mcp_servers,
                model=model,
            ):
                if evt.get("session_id"):
                    self._session_tenants[str(evt["session_id"])] = tenant_id
                yield evt
            return

        if not cfg.acp_enabled:
            yield build_friendly_acp_error(
                "Local ACP runtime is disabled on this server. "
                "Connect veraxi-runner with --enable-acp or set ACP_ENABLED=true for self-hosted local mode."
            )
            return

        try:
            async for evt in self.local_driver.stream_prompt(
                tenant_id=tenant_id,
                thread_id=thread_id,
                prompt_text=prompt_text,
                cwd=effective_cwd,
                mcp_servers=mcp_servers,
                model=model,
            ):
                if evt.get("session_id"):
                    self._session_tenants[str(evt["session_id"])] = tenant_id
                yield evt
        except AcpDriverError as exc:
            yield build_friendly_acp_error(str(exc))

    async def resolve_permission(
        self, tenant_id: str, session_id: str, request_id: str, outcome: str
    ) -> bool:
        if await self.local_driver.resolve_permission(session_id, request_id, outcome):
            return True
        return await self.runner_transport.resolve_permission(
            tenant_id, session_id, request_id, outcome
        )

    async def cancel_session(self, tenant_id: str, session_id: str) -> bool:
        if await self.local_driver.cancel_session_turn(session_id):
            return True
        return await self.runner_transport.cancel_session_turn(tenant_id, session_id)

    async def close_session(self, session_id: str) -> None:
        self._session_tenants.pop(session_id, None)
        await self.local_driver.close_session(session_id)


_GLOBAL_BROKER: AcpSessionBroker | None = None


def get_acp_broker() -> AcpSessionBroker:
    """Return the process-wide AcpSessionBroker singleton."""
    global _GLOBAL_BROKER
    if _GLOBAL_BROKER is None:
        _GLOBAL_BROKER = AcpSessionBroker()
    return _GLOBAL_BROKER


def set_acp_broker(broker: AcpSessionBroker | None) -> None:
    """Override the global AcpSessionBroker (test seam)."""
    global _GLOBAL_BROKER
    _GLOBAL_BROKER = broker
