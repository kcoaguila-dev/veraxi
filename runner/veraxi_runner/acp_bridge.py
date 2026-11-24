"""Local ACP subprocess bridge for ``veraxi-runner``.

Spawns the official ``agy acp`` binary on the user's workstation inside the
runner's repo directory and forwards raw ACP JSON-RPC frames over the
outbound WebSocket without touching or uploading OAuth credentials.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import shutil
import uuid
from collections.abc import Callable, Coroutine
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)

_ENV_ALLOWLIST = (
    "PATH",
    "HOME",
    "LANG",
    "LC_ALL",
    "TERM",
    "TMPDIR",
    "USER",
    "LOGNAME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "ANTIGRAVITY_DATA_DIR",
)


def _scrubbed_env() -> dict[str, str]:
    return {k: os.environ[k] for k in _ENV_ALLOWLIST if k in os.environ and os.environ[k]}


def _encode(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")


@dataclass
class _RunnerAcpSession:
    session_id: str
    process: Any
    acp_session_id: str = ""
    pending_rpc: dict[str, asyncio.Future[dict[str, Any]]] = field(default_factory=dict)
    pending_permissions: dict[str, str | int] = field(default_factory=dict)
    turn_queue: asyncio.Queue[dict[str, Any]] | None = None
    reader_task: asyncio.Task[None] | None = None


class RunnerAcpBridge:
    """Manages local ``agy acp`` sessions for ``veraxi-runner``."""

    def __init__(self, repo_root: str, binary: str = "agy", enabled: bool = False):
        self.repo_root = repo_root
        self.binary = binary
        self.enabled = enabled
        self._sessions: dict[str, _RunnerAcpSession] = {}

    async def handle(
        self,
        method: str,
        params: dict[str, Any],
        emit: Callable[[dict[str, Any]], Coroutine[Any, Any, None]],
    ) -> dict[str, Any]:
        if not self.enabled:
            raise RuntimeError("ACP bridge is disabled on this veraxi-runner (pass --enable-acp)")
        if method == "acp.health":
            resolved = shutil.which(self.binary)
            return {"available": resolved is not None, "binary": resolved or self.binary}
        if method == "acp.prompt":
            await self._handle_prompt(params, emit)
            return {"done": True}
        if method == "acp.permission":
            return await self._handle_permission(params)
        if method == "acp.cancel":
            return await self._handle_cancel(params)
        if method == "acp.stop":
            await self.close_session(str(params.get("session_id") or ""))
            return {"stopped": True}
        raise RuntimeError(f"Unsupported ACP runner method: {method}")

    async def _get_or_spawn(self, session_id: str, mcp_servers: list[dict[str, Any]]) -> _RunnerAcpSession:
        existing = self._sessions.get(session_id)
        if existing and existing.process.returncode is None:
            return existing
        resolved = shutil.which(self.binary)
        if not resolved:
            raise RuntimeError(f"Antigravity binary '{self.binary}' not found on PATH")
        proc = await asyncio.create_subprocess_exec(
            resolved,
            "acp",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=self.repo_root,
            env=_scrubbed_env(),
        )
        sess = _RunnerAcpSession(session_id=session_id, process=proc)
        sess.reader_task = asyncio.create_task(self._read_loop(sess))
        self._sessions[session_id] = sess

        await self._rpc(
            sess,
            "initialize",
            {
                "protocolVersion": 1,
                "clientInfo": {"name": "veraxi-runner", "version": "1.0.0"},
                "capabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
            },
        )
        res = await self._rpc(
            sess,
            "session/new",
            {"cwd": self.repo_root, "mcpServers": mcp_servers},
        )
        sess.acp_session_id = str(res.get("sessionId") or session_id)
        return sess

    async def _rpc(self, sess: _RunnerAcpSession, method: str, params: dict[str, Any]) -> dict[str, Any]:
        req_id = uuid.uuid4().hex
        fut: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        sess.pending_rpc[req_id] = fut
        try:
            sess.process.stdin.write(_encode({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}))
            await sess.process.stdin.drain()
            msg = await asyncio.wait_for(fut, timeout=300.0)
        finally:
            sess.pending_rpc.pop(req_id, None)
        if msg.get("error"):
            raise RuntimeError(str(msg["error"]))
        return msg.get("result") or {}

    async def _read_loop(self, sess: _RunnerAcpSession) -> None:
        try:
            while True:
                line = await sess.process.stdout.readline()
                if not line:
                    break
                try:
                    msg = json.loads(line.decode("utf-8", errors="replace"))
                except ValueError:
                    continue
                if not isinstance(msg, dict):
                    continue
                msg_id = msg.get("id")
                if msg_id is not None and msg.get("method") is None:
                    fut = sess.pending_rpc.get(str(msg_id))
                    if fut and not fut.done():
                        fut.set_result(msg)
                    continue
                if sess.turn_queue is not None:
                    await sess.turn_queue.put(msg)
        except asyncio.CancelledError:
            raise
        finally:
            if sess.turn_queue is not None:
                sess.turn_queue.put_nowait({"_eof": True})

    async def _handle_prompt(
        self,
        params: dict[str, Any],
        emit: Callable[[dict[str, Any]], Coroutine[Any, Any, None]],
    ) -> None:
        session_id = str(params.get("session_id") or uuid.uuid4().hex)
        prompt = str(params.get("prompt") or "")
        mcp_servers = params.get("mcp_servers") or []
        sess = await self._get_or_spawn(session_id, mcp_servers)
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        sess.turn_queue = queue
        task = asyncio.create_task(
            self._rpc(
                sess,
                "session/prompt",
                {"sessionId": sess.acp_session_id, "prompt": [{"type": "text", "text": prompt}]},
            )
        )
        try:
            while not task.done() or not queue.empty():
                if queue.empty():
                    wait = asyncio.create_task(queue.get())
                    done, _ = await asyncio.wait({task, wait}, return_when=asyncio.FIRST_COMPLETED)
                    if wait not in done:
                        wait.cancel()
                        continue
                    msg = wait.result()
                else:
                    msg = queue.get_nowait()
                if msg.get("_eof"):
                    break
                if msg.get("method") == "session/request_permission":
                    sess.pending_permissions[str(msg.get("id"))] = msg["id"]
                await emit({"acp_message": msg})
            await task
            await emit({"done": True})
        finally:
            sess.turn_queue = None

    async def _handle_permission(self, params: dict[str, Any]) -> dict[str, Any]:
        sess = self._sessions.get(str(params.get("session_id") or ""))
        if not sess:
            return {"resolved": False}
        req_id_str = str(params.get("request_id") or "")
        raw_id = sess.pending_permissions.pop(req_id_str, None)
        if raw_id is None:
            return {"resolved": False}
        outcome = str(params.get("outcome") or "deny")
        result = (
            {"outcome": {"outcome": "cancelled"}}
            if outcome == "deny"
            else {"outcome": {"outcome": "selected", "optionId": outcome}}
        )
        sess.process.stdin.write(_encode({"jsonrpc": "2.0", "id": raw_id, "result": result}))
        await sess.process.stdin.drain()
        return {"resolved": True}

    async def _handle_cancel(self, params: dict[str, Any]) -> dict[str, Any]:
        sess = self._sessions.get(str(params.get("session_id") or ""))
        if not sess or sess.process.returncode is not None:
            return {"cancelled": False}
        sess.process.stdin.write(
            _encode({"jsonrpc": "2.0", "id": uuid.uuid4().hex, "method": "session/cancel", "params": {"sessionId": sess.acp_session_id}})
        )
        await sess.process.stdin.drain()
        return {"cancelled": True}

    async def close_session(self, session_id: str) -> None:
        sess = self._sessions.pop(session_id, None)
        if not sess:
            return
        if sess.reader_task:
            sess.reader_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await sess.reader_task
        if sess.process.returncode is None:
            sess.process.terminate()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(sess.process.wait(), timeout=3.0)
