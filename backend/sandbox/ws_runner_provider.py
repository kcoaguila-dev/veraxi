"""Outbound-WebSocket runner provider (``veraxi-runner``).

The runner on user-owned hardware connects *outbound* to the backend,
so no inbound ports are needed. This provider keeps an in-process
registry ``tenant_id -> WebSocket`` and dispatches JSON-RPC requests
(``exec`` / ``read_file`` / ``write_file`` / ``diff``) down the active
socket for the tenant, streaming stdout/stderr back through asyncio
queues keyed by request id. Timeouts fail closed.
"""

import asyncio
import json
import logging
import uuid

import sentry_sdk

from backend.sandbox.base import ExecEvent, SandboxError, SandboxProvider, SandboxSessionInfo

logger = logging.getLogger(__name__)

REQUEST_TIMEOUT_SEC = 30.0


class RunnerRegistry:
    """In-process map of tenant_id -> connected runner websocket."""

    def __init__(self):
        self._sockets: dict[str, object] = {}

    def register(self, tenant_id: str, websocket) -> None:
        self._sockets[tenant_id] = websocket

    def unregister(self, tenant_id: str, websocket=None) -> None:
        current = self._sockets.get(tenant_id)
        if websocket is None or current is websocket:
            self._sockets.pop(tenant_id, None)

    def get(self, tenant_id: str):
        return self._sockets.get(tenant_id)

    def is_connected(self, tenant_id: str) -> bool:
        return tenant_id in self._sockets


# Process-wide registry shared by the WS route and the provider.
GLOBAL_REGISTRY = RunnerRegistry()


class WsRunnerProvider(SandboxProvider):
    provider_name = "local_runner"

    def __init__(self, settings: dict, secrets: dict | None = None, registry: RunnerRegistry | None = None):
        super().__init__(settings, secrets)
        self.registry = registry or GLOBAL_REGISTRY
        self._infos: dict[str, SandboxSessionInfo] = {}
        self._pending: dict[str, asyncio.Queue] = {}
        self._request_timeout = float(
            (settings or {}).get("config", {}).get("request_timeout_sec")
            or REQUEST_TIMEOUT_SEC
        ) if isinstance((settings or {}).get("config"), dict) else REQUEST_TIMEOUT_SEC

    # -- transport ------------------------------------------------------
    async def _send(self, tenant_id: str, payload: dict) -> None:
        websocket = self.registry.get(tenant_id)
        if websocket is None:
            raise SandboxError("No veraxi-runner is connected for this tenant")
        text = json.dumps(payload)
        send_text = getattr(websocket, "send_text", None)
        if callable(send_text):
            result = send_text(text)
            if asyncio.iscoroutine(result):
                await result
            return
        send = getattr(websocket, "send", None)
        if callable(send):
            result = send(text)
            if asyncio.iscoroutine(result):
                await result
            return
        raise SandboxError("Runner websocket does not support sending")

    async def handle_message(self, tenant_id: str, raw: str) -> None:
        """Route one inbound runner message to its pending request."""
        try:
            message = json.loads(raw)
        except ValueError as e:
            sentry_sdk.capture_exception(e)
            logger.warning("Runner sent non-JSON message for tenant %s", tenant_id)
            return
        request_id = message.get("id")
        queue = self._pending.get(str(request_id)) if request_id is not None else None
        if queue is not None:
            await queue.put(message)

    async def _request(self, tenant_id: str, method: str, params: dict, timeout: float | None = None) -> dict:
        request_id = uuid.uuid4().hex
        queue: asyncio.Queue = asyncio.Queue()
        self._pending[request_id] = queue
        try:
            await self._send(tenant_id, {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            message = await asyncio.wait_for(queue.get(), timeout=timeout or self._request_timeout)
        except TimeoutError as e:
            raise SandboxError(f"Runner request {method} timed out") from e
        finally:
            self._pending.pop(request_id, None)
        if message.get("error"):
            raise SandboxError(str(message["error"]))
        result = message.get("result")
        return result if isinstance(result, dict) else {"value": result}

    # -- provider API ---------------------------------------------------
    async def start_session(self, tenant_id: str, repo_url: str | None = None) -> SandboxSessionInfo:
        if not self.registry.is_connected(tenant_id):
            raise SandboxError("No veraxi-runner is connected for this tenant")
        info = SandboxSessionInfo(tenant_id=tenant_id, provider=self.provider_name, status="running")
        self._infos[info.session_id] = info
        if repo_url:
            info.git_branch = await self._maybe_clone_repo(info.session_id, repo_url)
        info.touch()
        return info

    def _tenant_for(self, session_id: str) -> str:
        info = self._infos.get(session_id)
        if info is None:
            raise SandboxError(f"Unknown runner session {session_id}")
        return info.tenant_id

    async def exec_command(self, session_id: str, cmd: str, cwd: str | None = None, timeout_sec: int = 120):
        tenant_id = self._tenant_for(session_id)
        request_id = uuid.uuid4().hex
        queue: asyncio.Queue = asyncio.Queue()
        self._pending[request_id] = queue
        try:
            await self._send(tenant_id, {
                "jsonrpc": "2.0", "id": request_id, "method": "exec",
                "params": {"command": cmd, "cwd": cwd, "timeout_sec": timeout_sec},
            })
            deadline = timeout_sec + self._request_timeout
            while True:
                message = await asyncio.wait_for(queue.get(), timeout=deadline)
                if message.get("error"):
                    yield ExecEvent(kind="stderr", data=str(message["error"]))
                    yield ExecEvent(kind="exit", data="", exit_code=1)
                    return
                result = message.get("result") or {}
                kind = result.get("type") or result.get("kind") or "stdout"
                if kind == "exit":
                    yield ExecEvent(kind="exit", data="", exit_code=int(result.get("exit_code") or 0))
                    return
                if kind in ("stdout", "stderr"):
                    yield ExecEvent(kind=kind, data=str(result.get("data") or ""))
                elif "exit_code" in result:  # single-shot (non-streaming) reply
                    if result.get("stdout"):
                        yield ExecEvent(kind="stdout", data=str(result["stdout"]))
                    if result.get("stderr"):
                        yield ExecEvent(kind="stderr", data=str(result["stderr"]))
                    yield ExecEvent(kind="exit", data="", exit_code=int(result.get("exit_code") or 0))
                    return
        except TimeoutError:
            yield ExecEvent(kind="stderr", data="Runner exec timed out")
            yield ExecEvent(kind="exit", data="", exit_code=1)
        except SandboxError as e:
            yield ExecEvent(kind="stderr", data=str(e))
            yield ExecEvent(kind="exit", data="", exit_code=1)
        finally:
            self._pending.pop(request_id, None)
            info = self._infos.get(session_id)
            if info:
                info.touch()

    async def read_file(self, session_id: str, path: str) -> str:
        result = await self._request(self._tenant_for(session_id), "read_file", {"path": path})
        return str(result.get("content") or result.get("value") or "")

    async def write_file(self, session_id: str, path: str, content: str) -> None:
        await self._request(self._tenant_for(session_id), "write_file", {"path": path, "content": content})

    async def get_diff(self, session_id: str) -> str:
        result = await self._request(self._tenant_for(session_id), "diff", {})
        return str(result.get("diff") or result.get("value") or "")

    async def stop_session(self, session_id: str) -> None:
        self._infos.pop(session_id, None)
