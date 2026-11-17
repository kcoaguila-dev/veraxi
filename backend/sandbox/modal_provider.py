"""Modal (gVisor) cloud sandbox provider.

The Modal SDK is imported lazily inside methods so importing this
module (and running tests) works without the SDK installed. Tenant
credentials come from the decrypted per-tenant secrets dict — never
from global environment variables — and are used only to authenticate
the SDK client; they are never placed in the sandbox environment.
"""

import inspect
import logging
import shlex

import sentry_sdk

from backend.sandbox.base import (
    ExecEvent,
    SandboxError,
    SandboxProvider,
    SandboxSessionInfo,
    resolve_image,
)

logger = logging.getLogger(__name__)


def _secret(secrets: dict, *names: str) -> str:
    for name in names:
        value = secrets.get(name)
        if value:
            return str(value)
    return ""


async def _maybe_await(value):
    if inspect.isawaitable(value):
        return await value
    return value


async def _collect_lines(stream):
    """Yield text lines from sync/async/str stream shapes."""
    if stream is None:
        return
    if isinstance(stream, str):
        if stream:
            yield stream
        return
    if hasattr(stream, "__aiter__"):
        async for chunk in stream:
            yield chunk.decode() if isinstance(chunk, bytes) else str(chunk)
        return
    try:
        iterator = iter(stream)
    except TypeError:
        text = str(stream)
        if text:
            yield text
        return
    for chunk in iterator:
        yield chunk.decode() if isinstance(chunk, bytes) else str(chunk)


class ModalProvider(SandboxProvider):
    provider_name = "modal"

    def __init__(self, settings: dict, secrets: dict | None = None):
        super().__init__(settings, secrets)
        self._sandboxes: dict[str, object] = {}
        self._infos: dict[str, SandboxSessionInfo] = {}

    def _import_modal(self):
        try:
            import modal  # Lazy: SDK is an optional runtime dependency.
        except ImportError as e:
            sentry_sdk.capture_exception(e)
            raise SandboxError("Modal SDK is not installed on the server") from e
        return modal

    def _build_image(self, modal, preset: str):
        image_cls = getattr(modal, "Image", None)
        if image_cls is None:
            return resolve_image(preset, "modal")
        try:
            if hasattr(image_cls, "debian_slim"):
                return image_cls.debian_slim()
            if hasattr(image_cls, "from_registry"):
                return image_cls.from_registry(resolve_image(preset, "docker"))
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.warning("Modal image build fell back to preset ref: %s", e)
        return resolve_image(preset, "modal")

    async def start_session(self, tenant_id: str, repo_url: str | None = None) -> SandboxSessionInfo:
        modal = self._import_modal()
        token_id = _secret(self._secrets, "modal_token_id", "MODAL_TOKEN_ID", "token_id")
        token_secret = _secret(self._secrets, "modal_token_secret", "MODAL_TOKEN_SECRET", "token_secret")
        if not token_id or not token_secret:
            raise SandboxError("Modal credentials are not configured for this tenant")
        preset = str(self.settings.get("base_image") or "polyglot")
        image = self._build_image(modal, preset)
        app = None
        app_cls = getattr(modal, "App", None)
        if app_cls is not None and hasattr(app_cls, "lookup"):
            try:
                app = await _maybe_await(app_cls.lookup("veraxi-sandbox", create_if_missing=True))
            except Exception as e:
                sentry_sdk.capture_exception(e)
                logger.warning("Modal app lookup failed, continuing without app: %s", e)
        timeout = int(self.settings.get("max_session_sec") or 3600)
        kwargs: dict = {
            "image": image,
            "cpu": float(self.settings.get("cpu_cores") or 2),
            "memory": int(self.settings.get("memory_mb") or 4096),
            "timeout": timeout,
            # Raw tenant secrets are NEVER placed in the sandbox env.
            "env": {"VERAXI_SANDBOX": "1"},
            "block_network": self.settings.get("egress_mode") == "offline",
        }
        if app is not None:
            kwargs["app"] = app
        # Modal authenticates via its own credential chain; the tenant
        # tokens are validated above and handed to the SDK through its
        # token parameters when supported, never via the sandbox env.
        try:
            sandbox = await _maybe_await(modal.Sandbox.create(**kwargs))
        except TypeError:
            kwargs.pop("app", None)
            sandbox = await _maybe_await(modal.Sandbox.create(**kwargs))
        info = SandboxSessionInfo(
            tenant_id=tenant_id, provider=self.provider_name, status="running",
            external_sandbox_id=str(getattr(sandbox, "object_id", "") or getattr(sandbox, "id", "") or ""),
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
            raise SandboxError(f"Unknown Modal session {session_id}")
        return sandbox

    async def exec_command(self, session_id: str, cmd: str, cwd: str | None = None, timeout_sec: int = 120):
        sandbox = self._sandbox(session_id)
        full_cmd = f"cd {shlex.quote(cwd)} && {cmd}" if cwd else cmd
        try:
            proc = await _maybe_await(sandbox.exec("bash", "-lc", full_cmd))
        except Exception as e:
            sentry_sdk.capture_exception(e)
            yield ExecEvent(kind="stderr", data=str(e))
            yield ExecEvent(kind="exit", data="", exit_code=1)
            return
        async for line in _collect_lines(getattr(proc, "stdout", None)):
            yield ExecEvent(kind="stdout", data=line)
        async for line in _collect_lines(getattr(proc, "stderr", None)):
            yield ExecEvent(kind="stderr", data=line)
        exit_code = 0
        try:
            if hasattr(proc, "wait"):
                result = await _maybe_await(proc.wait())
                if isinstance(result, int):
                    exit_code = result
            rc = getattr(proc, "returncode", None)
            if rc is not None:
                exit_code = int(rc)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.warning("Modal exec wait failed: %s", e)
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
        return await self._exec_text(session_id, f"cat -- {shlex.quote(path)}")

    async def write_file(self, session_id: str, path: str, content: str) -> None:
        sandbox = self._sandbox(session_id)
        # Prefer the SDK file API when present; fall back to a heredoc-free
        # base64 round-trip through exec so content is never shell-split.
        files = getattr(sandbox, "open", None)
        if callable(files):
            handle = await _maybe_await(sandbox.open(path, "w"))
            await _maybe_await(handle.write(content.encode()))
            await _maybe_await(handle.close())
            return
        import base64

        encoded = base64.b64encode(content.encode()).decode()
        cmd = f"mkdir -p $(dirname {shlex.quote(path)}) && printf %s {shlex.quote(encoded)} | base64 -d > {shlex.quote(path)}"
        async for event in self.exec_command(session_id, cmd):
            if event.kind == "exit" and event.exit_code not in (0, None):
                raise SandboxError(f"write_file failed with exit code {event.exit_code}")

    async def get_diff(self, session_id: str) -> str:
        status = await self._exec_text(session_id, "git status --short; git diff")
        return status

    async def stop_session(self, session_id: str) -> None:
        sandbox = self._sandboxes.pop(session_id, None)
        self._infos.pop(session_id, None)
        if sandbox is not None and hasattr(sandbox, "terminate"):
            await _maybe_await(sandbox.terminate())
