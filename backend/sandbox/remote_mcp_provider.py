"""Remote MCP sandbox provider (user-owned hardware, direct MCP).

Connects to a tenant's self-hosted MCP sandbox endpoint (e.g.
Microsandbox exposed over Tailscale / Cloudflare Tunnel) and maps the
:class:`SandboxProvider` methods onto remote MCP tool calls. Tool
names are configurable via the config JSON (``exec_tool``,
``read_file_tool``, ``write_file_tool``, ``diff_tool``); transport
reuses :mod:`backend.services.mcp_client_manager` (SSRF re-validation,
transport fallback, timeouts). The URL is additionally SSRF-validated
here before any connection, and the bearer token comes only from the
decrypted per-tenant secrets.
"""

import logging

import sentry_sdk

from backend.sandbox.base import ExecEvent, SandboxError, SandboxProvider, SandboxSessionInfo
from backend.security.ssrf import SsrfBlockedError, validate_external_url

logger = logging.getLogger(__name__)

_DEFAULT_TOOLS = {
    "exec": "exec",
    "read_file": "read_file",
    "write_file": "write_file",
    "diff": "diff",
}


def _result_text(result) -> str:
    """Extract plain text from an MCP SDK call result / plain value."""
    if result is None:
        return ""
    if isinstance(result, str):
        return result
    if isinstance(result, dict):
        for key in ("content", "text", "stdout", "diff", "value"):
            if result.get(key):
                return str(result[key])
        return str(result)
    content = getattr(result, "content", None)
    if content:
        parts = []
        for item in content:
            text = getattr(item, "text", None)
            if text:
                parts.append(str(text))
            elif isinstance(item, dict) and item.get("text"):
                parts.append(str(item["text"]))
        if parts:
            return "\n".join(parts)
    return str(result)


class RemoteMcpProvider(SandboxProvider):
    provider_name = "remote_mcp"

    def __init__(self, settings: dict, secrets: dict | None = None, tool_caller=None):
        super().__init__(settings, secrets)
        cfg = self.settings.get("config") or {}
        self.url = str(cfg.get("url") or cfg.get("mcp_url") or "")
        self.transport = str(cfg.get("transport") or "auto")
        self.tool_names = {**_DEFAULT_TOOLS}
        for key, cfg_key in (
            ("exec", "exec_tool"), ("read_file", "read_file_tool"),
            ("write_file", "write_file_tool"), ("diff", "diff_tool"),
        ):
            if cfg.get(cfg_key):
                self.tool_names[key] = str(cfg[cfg_key])
        token = (
            self._secrets.get("bearer_token") or self._secrets.get("token")
            or self._secrets.get("access_token") or ""
        )
        headers = dict(self._secrets.get("headers") or {})
        if token and "Authorization" not in headers:
            headers["Authorization"] = f"Bearer {token}"
        self.headers = headers
        self._tool_caller = tool_caller  # injectable seam for tests
        self._infos: dict[str, SandboxSessionInfo] = {}

    def _validate(self) -> None:
        if not self.url:
            raise SandboxError("Remote MCP sandbox URL is not configured")
        try:
            validate_external_url(self.url)
        except SsrfBlockedError as e:
            raise SandboxError(str(e)) from e

    async def _call(self, logical_name: str, args: dict):
        self._validate()
        tool_name = self.tool_names[logical_name]
        if self._tool_caller is not None:
            result = self._tool_caller(tool_name, args)
            if hasattr(result, "__await__"):
                result = await result
            return result
        from backend.services import mcp_client_manager as mcp_manager

        spec = mcp_manager.McpServerSpec(
            slug="sandbox", url=self.url, transport=self.transport,
            headers=self.headers, integration_id="sandbox-remote",
            display_name="Remote MCP Sandbox",
        )
        full_name = mcp_manager.sanitize_tool_name("sandbox", tool_name)
        return await mcp_manager.call_tool(spec, "", full_name, args)

    async def start_session(self, tenant_id: str, repo_url: str | None = None) -> SandboxSessionInfo:
        self._validate()
        info = SandboxSessionInfo(tenant_id=tenant_id, provider=self.provider_name, status="running")
        self._infos[info.session_id] = info
        if repo_url:
            info.git_branch = await self._maybe_clone_repo(info.session_id, repo_url)
        info.touch()
        return info

    def _check(self, session_id: str) -> None:
        if session_id not in self._infos:
            raise SandboxError(f"Unknown remote MCP session {session_id}")

    async def exec_command(self, session_id: str, cmd: str, cwd: str | None = None, timeout_sec: int = 120):
        self._check(session_id)
        try:
            result = await self._call("exec", {"command": cmd, "cwd": cwd, "timeout_sec": timeout_sec})
        except Exception as e:
            sentry_sdk.capture_exception(e)
            yield ExecEvent(kind="stderr", data=str(e))
            yield ExecEvent(kind="exit", data="", exit_code=1)
            return
        exit_code = 0
        if isinstance(result, dict):
            if result.get("stdout"):
                yield ExecEvent(kind="stdout", data=str(result["stdout"]))
            if result.get("stderr"):
                yield ExecEvent(kind="stderr", data=str(result["stderr"]))
            exit_code = int(result.get("exit_code") or 0)
        else:
            text = _result_text(result)
            if text:
                yield ExecEvent(kind="stdout", data=text)
        info = self._infos.get(session_id)
        if info:
            info.touch()
        yield ExecEvent(kind="exit", data="", exit_code=exit_code)

    async def read_file(self, session_id: str, path: str) -> str:
        self._check(session_id)
        return _result_text(await self._call("read_file", {"path": path}))

    async def write_file(self, session_id: str, path: str, content: str) -> None:
        self._check(session_id)
        await self._call("write_file", {"path": path, "content": content})

    async def get_diff(self, session_id: str) -> str:
        self._check(session_id)
        return _result_text(await self._call("diff", {}))

    async def stop_session(self, session_id: str) -> None:
        self._infos.pop(session_id, None)
