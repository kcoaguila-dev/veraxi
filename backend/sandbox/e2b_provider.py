"""E2B (Firecracker) cloud sandbox provider.

The E2B SDK is imported lazily inside methods so importing this module
works without the SDK installed. The tenant's ``E2B_API_KEY`` comes
from decrypted per-tenant secrets — never global env — and is passed
only as the SDK ``api_key`` argument, never into the sandbox env.
Supports pause/resume on idle timeout via the SDK.
"""

import logging
import shlex

import sentry_sdk

from backend.sandbox.base import ExecEvent, SandboxError, SandboxProvider, SandboxSessionInfo
from backend.sandbox.modal_provider import _maybe_await, _secret

logger = logging.getLogger(__name__)


class E2BProvider(SandboxProvider):
    provider_name = "e2b"

    def __init__(self, settings: dict, secrets: dict | None = None):
        super().__init__(settings, secrets)
        self._sandboxes: dict[str, object] = {}
        self._infos: dict[str, SandboxSessionInfo] = {}

    def _import_e2b(self):
        try:
            import e2b  # Lazy: SDK is an optional runtime dependency.
        except ImportError as e:
            sentry_sdk.capture_exception(e)
            raise SandboxError("E2B SDK is not installed on the server") from e
        return e2b

    def _api_key(self) -> str:
        key = _secret(self._secrets, "e2b_api_key", "E2B_API_KEY", "api_key")
        if not key:
            raise SandboxError("E2B API key is not configured for this tenant")
        return key

    async def start_session(self, tenant_id: str, repo_url: str | None = None) -> SandboxSessionInfo:
        e2b = self._import_e2b()
        api_key = self._api_key()
        timeout = int(self.settings.get("max_session_sec") or 3600)
        allow_net = self.settings.get("egress_mode") != "offline"
        kwargs: dict = {
            "api_key": api_key,
            "timeout": timeout,
            "cpu_count": int(self.settings.get("cpu_cores") or 2),
            "memory_mb": int(self.settings.get("memory_mb") or 4096),
            "allow_internet_access": allow_net,
            # Raw tenant secrets are NEVER placed in the sandbox env.
            "envs": {"VERAXI_SANDBOX": "1"},
        }
        try:
            sandbox = await _maybe_await(e2b.Sandbox.create(**kwargs))
        except TypeError:
            minimal = {"api_key": api_key, "timeout": timeout, "allow_internet_access": allow_net}
            sandbox = await _maybe_await(e2b.Sandbox.create(**minimal))
        info = SandboxSessionInfo(
            tenant_id=tenant_id, provider=self.provider_name, status="running",
            external_sandbox_id=str(getattr(sandbox, "sandbox_id", "") or getattr(sandbox, "id", "") or ""),
        )
        self._sandboxes[info.session_id] = sandbox
        self._infos[info.session_id] = info
        if repo_url:
            info.git_branch = await self._maybe_clone_repo(info.session_id, repo_url)
        info.touch()
        return info

    def _sandbox(self, session_id: str):
        sandbox = self._sandboxes.get(session_id)
        if sandbox is None:
            raise SandboxError(f"Unknown E2B session {session_id}")
        return sandbox

    async def exec_command(self, session_id: str, cmd: str, cwd: str | None = None, timeout_sec: int = 120):
        sandbox = self._sandbox(session_id)
        full_cmd = f"cd {shlex.quote(cwd)} && {cmd}" if cwd else cmd
        try:
            commands = getattr(sandbox, "commands", None)
            if commands is not None and hasattr(commands, "run"):
                result = await _maybe_await(commands.run(full_cmd, timeout=timeout_sec))
                stdout = getattr(result, "stdout", "") or ""
                stderr = getattr(result, "stderr", "") or ""
                exit_code = int(getattr(result, "exit_code", 0) or 0)
            else:
                result = await _maybe_await(sandbox.run_code(full_cmd))  # pragma: no cover
                stdout, stderr, exit_code = str(result), "", 0
        except Exception as e:
            # E2B raises CommandExitException carrying stdout/stderr.
            stdout = getattr(e, "stdout", "") or ""
            stderr = getattr(e, "stderr", "") or str(e)
            exit_code = int(getattr(e, "exit_code", 1) or 1)
            if stdout:
                yield ExecEvent(kind="stdout", data=stdout)
            yield ExecEvent(kind="stderr", data=stderr)
            yield ExecEvent(kind="exit", data="", exit_code=exit_code)
            return
        if stdout:
            yield ExecEvent(kind="stdout", data=stdout)
        if stderr:
            yield ExecEvent(kind="stderr", data=stderr)
        info = self._infos.get(session_id)
        if info:
            info.touch()
        yield ExecEvent(kind="exit", data="", exit_code=exit_code)

    async def _exec_text(self, session_id: str, cmd: str) -> str:
        parts: list[str] = []
        async for event in self.exec_command(session_id, cmd):
            if event.kind == "stdout":
                parts.append(event.data)
        return "".join(parts)

    async def read_file(self, session_id: str, path: str) -> str:
        sandbox = self._sandbox(session_id)
        files = getattr(sandbox, "files", None)
        if files is not None and hasattr(files, "read"):
            result = await _maybe_await(files.read(path))
            return result if isinstance(result, str) else result.decode()
        return await self._exec_text(session_id, f"cat -- {shlex.quote(path)}")

    async def write_file(self, session_id: str, path: str, content: str) -> None:
        sandbox = self._sandbox(session_id)
        files = getattr(sandbox, "files", None)
        if files is not None and hasattr(files, "write"):
            await _maybe_await(files.write(path, content))
            return
        raise SandboxError("E2B sandbox does not expose a file-write API")

    async def get_diff(self, session_id: str) -> str:
        return await self._exec_text(session_id, "git status --short; git diff")

    async def pause_session(self, session_id: str) -> None:
        sandbox = self._sandbox(session_id)
        if hasattr(sandbox, "pause"):
            await _maybe_await(sandbox.pause())
        else:  # pragma: no cover - older SDK shape
            e2b = self._import_e2b()
            await _maybe_await(e2b.Sandbox.pause(self._infos[session_id].external_sandbox_id, api_key=self._api_key()))
        self._infos[session_id].status = "paused"

    async def resume_session(self, session_id: str) -> None:
        info = self._infos.get(session_id)
        if info is None:
            raise SandboxError(f"Unknown E2B session {session_id}")
        e2b = self._import_e2b()
        sandbox = None
        if hasattr(e2b.Sandbox, "resume"):
            sandbox = await _maybe_await(e2b.Sandbox.resume(info.external_sandbox_id, api_key=self._api_key()))
        elif hasattr(e2b.Sandbox, "connect"):
            sandbox = await _maybe_await(e2b.Sandbox.connect(info.external_sandbox_id, api_key=self._api_key()))
        if sandbox is not None:
            self._sandboxes[session_id] = sandbox
        info.status = "running"
        info.touch()

    async def stop_session(self, session_id: str) -> None:
        sandbox = self._sandboxes.pop(session_id, None)
        self._infos.pop(session_id, None)
        if sandbox is not None:
            if hasattr(sandbox, "kill"):
                await _maybe_await(sandbox.kill())
            elif hasattr(sandbox, "close"):
                await _maybe_await(sandbox.close())
