"""Local ACP (Agent Client Protocol) subprocess driver for ``agy acp``.

Manages process-per-session lifecycles over NDJSON JSON-RPC 2.0 ``stdio``.
Environment variables are strictly scrubbed to an allowlist so backend
secrets (database passwords, Stripe/Supabase keys) never leak to child
processes.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import shutil
import uuid
from collections.abc import AsyncGenerator, Callable, Coroutine
from dataclasses import dataclass, field
from typing import Any

import sentry_sdk

from backend.acp.protocol import (
    AcpTurnAdapter,
    build_friendly_acp_error,
    build_initialize_params,
    build_session_new_params,
    build_session_prompt_params,
    encode_rpc_request,
    encode_rpc_response,
    parse_ndjson_line,
)

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


def build_scrubbed_env(base_env: dict[str, str] | None = None) -> dict[str, str]:
    """Return a minimal environment allowlist without Veraxi backend secrets."""
    source = base_env if base_env is not None else os.environ
    return {key: source[key] for key in _ENV_ALLOWLIST if source.get(key)}


class AcpDriverError(RuntimeError):
    """Raised when spawning or communicating with an ACP agent fails."""


@dataclass
class AcpSession:
    """Tracks one running ACP agent subprocess bound to a Veraxi thread."""

    veraxi_session_id: str
    tenant_id: str
    thread_id: str
    cwd: str
    process: Any
    acp_session_id: str = ""
    model: str | None = None
    last_used_at: float = field(default_factory=lambda: asyncio.get_event_loop().time())
    pending_rpc: dict[str, asyncio.Future[dict[str, Any]]] = field(default_factory=dict)
    pending_permissions: dict[str, asyncio.Future[str]] = field(default_factory=dict)
    turn_queue: asyncio.Queue[dict[str, Any]] | None = None
    reader_task: asyncio.Task[None] | None = None
    turn_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    def touch(self) -> None:
        self.last_used_at = asyncio.get_event_loop().time()


ProcessFactory = Callable[..., Coroutine[Any, Any, Any]]


class LocalAcpDriver:
    """Process-per-session manager for local ``agy acp`` subprocesses."""

    def __init__(
        self,
        binary: str = "agy",
        idle_timeout_sec: int = 900,
        max_sessions_per_tenant: int = 3,
        process_factory: ProcessFactory | None = None,
    ):
        self.binary = binary
        self.idle_timeout_sec = idle_timeout_sec
        self.max_sessions_per_tenant = max_sessions_per_tenant
        self._process_factory = process_factory
        self._sessions: dict[str, AcpSession] = {}
        self._thread_index: dict[tuple[str, str], str] = {}

    def is_available(self) -> tuple[bool, str | None]:
        """Return (available, resolved_path) for the configured ACP binary."""
        if self._process_factory is not None:
            return True, self.binary
        resolved = shutil.which(self.binary)
        return (resolved is not None), resolved

    async def get_or_create_session(
        self,
        tenant_id: str,
        thread_id: str,
        cwd: str,
        mcp_servers: list[dict[str, Any]] | None = None,
        model: str | None = None,
    ) -> AcpSession:
        """Return an active ACP session for (tenant_id, thread_id) or spawn a new one."""
        await self.reap_idle_sessions()
        effective_model = model if model and model != "antigravity-acp" else None
        key = (tenant_id, thread_id)
        existing_id = self._thread_index.get(key)
        if existing_id and existing_id in self._sessions:
            session = self._sessions[existing_id]
            if session.process.returncode is None:
                if effective_model and effective_model != session.model:
                    await self._set_session_model(session, effective_model)
                session.touch()
                return session
            await self.close_session(existing_id)

        tenant_sessions = [s for s in self._sessions.values() if s.tenant_id == tenant_id]
        if len(tenant_sessions) >= self.max_sessions_per_tenant:
            oldest = min(tenant_sessions, key=lambda s: s.last_used_at)
            await self.close_session(oldest.veraxi_session_id)

        return await self._spawn_session(tenant_id, thread_id, cwd, mcp_servers, model=effective_model)

    async def _set_session_model(self, session: AcpSession, model_id: str) -> None:
        try:
            await self._rpc_call(
                session,
                "session/set_model",
                {"sessionId": session.acp_session_id, "modelId": model_id},
                timeout=10.0,
            )
            session.model = model_id
        except AcpDriverError as exc:
            logger.warning("session/set_model failed for %s: %s", model_id, exc)

    async def _spawn_session(
        self,
        tenant_id: str,
        thread_id: str,
        cwd: str,
        mcp_servers: list[dict[str, Any]] | None,
        model: str | None = None,
    ) -> AcpSession:
        available, resolved = self.is_available()
        if not available or not resolved:
            raise AcpDriverError(
                f"Antigravity CLI binary '{self.binary}' was not found on PATH."
            )

        env = build_scrubbed_env()
        factory = self._process_factory or asyncio.create_subprocess_exec
        cli_args = ["--model", model, "acp"] if model else ["acp"]
        process = await factory(
            resolved,
            *cli_args,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd,
            env=env,
        )

        veraxi_session_id = uuid.uuid4().hex
        session = AcpSession(
            veraxi_session_id=veraxi_session_id,
            tenant_id=tenant_id,
            thread_id=thread_id,
            cwd=cwd,
            process=process,
            model=model,
        )
        session.reader_task = asyncio.create_task(self._read_stdout_loop(session))
        self._sessions[veraxi_session_id] = session
        self._thread_index[(tenant_id, thread_id)] = veraxi_session_id

        try:
            await self._rpc_call(session, "initialize", build_initialize_params(), timeout=15.0)
            new_res = await self._rpc_call(
                session,
                "session/new",
                build_session_new_params(cwd=cwd, mcp_servers=mcp_servers),
                timeout=15.0,
            )
            session.acp_session_id = str(new_res.get("sessionId") or veraxi_session_id)
            return session
        except Exception:
            await self.close_session(veraxi_session_id)
            raise

    async def _write_bytes(self, session: AcpSession, data: bytes) -> None:
        if session.process.stdin is None:
            raise AcpDriverError("ACP process stdin is closed")
        session.process.stdin.write(data)
        await session.process.stdin.drain()

    async def _rpc_call(
        self,
        session: AcpSession,
        method: str,
        params: dict[str, Any],
        timeout: float = 300.0,
    ) -> dict[str, Any]:
        req_id = uuid.uuid4().hex
        loop = asyncio.get_running_loop()
        fut: asyncio.Future[dict[str, Any]] = loop.create_future()
        session.pending_rpc[req_id] = fut
        try:
            await self._write_bytes(session, encode_rpc_request(req_id, method, params))
            msg = await asyncio.wait_for(fut, timeout=timeout)
        finally:
            session.pending_rpc.pop(req_id, None)

        if "error" in msg and msg["error"] is not None:
            err = msg["error"]
            detail = err.get("message") if isinstance(err, dict) else str(err)
            code = err.get("code") if isinstance(err, dict) else None
            raise AcpDriverError(json.dumps({"message": detail, "code": code}))
        result = msg.get("result")
        return result if isinstance(result, dict) else {}

    async def _read_stdout_loop(self, session: AcpSession) -> None:
        stdout = session.process.stdout
        if stdout is None:
            return
        try:
            while True:
                line = await stdout.readline()
                if not line:
                    break
                msg = parse_ndjson_line(line)
                if msg is None:
                    continue
                await self._dispatch_inbound_message(session, msg)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.exception("ACP stdout reader failed for session %s", session.veraxi_session_id)
        finally:
            self._fail_pending_futures(session, "ACP agent process exited unexpectedly")

    async def _dispatch_inbound_message(self, session: AcpSession, msg: dict[str, Any]) -> None:
        msg_id = msg.get("id")
        method = msg.get("method")
        if msg_id is not None and method is None:
            fut = session.pending_rpc.get(str(msg_id))
            if fut and not fut.done():
                fut.set_result(msg)
            return

        if session.turn_queue is not None:
            await session.turn_queue.put(msg)

    def _fail_pending_futures(self, session: AcpSession, reason: str) -> None:
        for fut in list(session.pending_rpc.values()):
            if not fut.done():
                fut.set_exception(AcpDriverError(reason))
        for fut in list(session.pending_permissions.values()):
            if not fut.done():
                fut.set_result("deny")
        if session.turn_queue is not None:
            session.turn_queue.put_nowait({"_acp_eof": True, "reason": reason})

    async def resolve_permission(self, veraxi_session_id: str, request_id: str, outcome: str) -> bool:
        """Resolve an active ``session/request_permission`` prompt."""
        session = self._sessions.get(veraxi_session_id)
        if not session:
            return False
        fut = session.pending_permissions.get(str(request_id))
        if not fut or fut.done():
            return False
        fut.set_result(outcome)
        return True

    async def cancel_session_turn(self, veraxi_session_id: str) -> bool:
        """Send ``session/cancel`` to an active ACP session."""
        session = self._sessions.get(veraxi_session_id)
        if not session or session.process.returncode is not None:
            return False
        await self._write_bytes(
            session,
            encode_rpc_request(
                uuid.uuid4().hex,
                "session/cancel",
                {"sessionId": session.acp_session_id},
            ),
        )
        return True

    async def stream_prompt(
        self,
        tenant_id: str,
        thread_id: str,
        prompt_text: str,
        cwd: str,
        mcp_servers: list[dict[str, Any]] | None = None,
        model: str | None = None,
    ) -> AsyncGenerator[dict[str, Any], None]:
        """Run one interactive prompt turn on ``agy acp`` and yield Veraxi SSE events."""
        session = await self.get_or_create_session(tenant_id, thread_id, cwd, mcp_servers, model=model)
        async with session.turn_lock:
            session.touch()
            adapter = AcpTurnAdapter(veraxi_session_id=session.veraxi_session_id)
            queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
            session.turn_queue = queue

            yield {
                "event": "on_step_start",
                "step": 1,
                "name": "Antigravity ACP",
                "description": "Running directly via local Antigravity CLI (user quota)...",
            }

            prompt_task = asyncio.create_task(
                self._rpc_call(
                    session,
                    "session/prompt",
                    build_session_prompt_params(session.acp_session_id, prompt_text),
                )
            )
            try:
                while not prompt_task.done() or not queue.empty():
                    if queue.empty():
                        done_wait = asyncio.create_task(queue.get())
                        finished, _ = await asyncio.wait(
                            {prompt_task, done_wait},
                            return_when=asyncio.FIRST_COMPLETED,
                        )
                        if done_wait not in finished:
                            done_wait.cancel()
                            continue
                        msg = done_wait.result()
                    else:
                        msg = queue.get_nowait()

                    if msg.get("_acp_eof"):
                        break
                    if msg.get("method") == "session/request_permission":
                        async for evt in self._handle_permission_flow(session, adapter, msg):
                            yield evt
                        continue
                    for sse_evt in adapter.translate_notification(msg):
                        yield sse_evt

                await prompt_task
                for sse_evt in adapter.finalize_turn():
                    yield sse_evt
            except AcpDriverError as exc:
                for sse_evt in adapter.finalize_turn():
                    yield sse_evt
                yield self._format_driver_error(exc)
            except Exception as exc:
                sentry_sdk.capture_exception(exc)
                for sse_evt in adapter.finalize_turn():
                    yield sse_evt
                yield build_friendly_acp_error(str(exc))
            finally:
                session.turn_queue = None
                session.touch()

    async def _handle_permission_flow(
        self,
        session: AcpSession,
        adapter: AcpTurnAdapter,
        msg: dict[str, Any],
    ) -> AsyncGenerator[dict[str, Any], None]:
        req_id = str(msg.get("id"))
        loop = asyncio.get_running_loop()
        fut: asyncio.Future[str] = loop.create_future()
        session.pending_permissions[req_id] = fut
        yield adapter.translate_permission_request(msg)
        try:
            outcome = await asyncio.wait_for(fut, timeout=300.0)
        except TimeoutError:
            outcome = "deny"
        finally:
            session.pending_permissions.pop(req_id, None)

        raw_id: str | int = msg["id"]
        if outcome == "deny":
            rpc_result: dict[str, Any] = {"outcome": {"outcome": "cancelled"}}
        else:
            rpc_result = {"outcome": {"outcome": "selected", "optionId": outcome}}
        await self._write_bytes(session, encode_rpc_response(raw_id, result=rpc_result))

    def _format_driver_error(self, exc: AcpDriverError) -> dict[str, Any]:
        raw = str(exc)
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                return build_friendly_acp_error(
                    str(parsed.get("message") or raw),
                    code=parsed.get("code"),
                )
        except ValueError:
            pass
        return build_friendly_acp_error(raw)

    async def close_session(self, veraxi_session_id: str) -> None:
        """Terminate an ACP session subprocess and clean up indices."""
        session = self._sessions.pop(veraxi_session_id, None)
        if not session:
            return
        self._thread_index.pop((session.tenant_id, session.thread_id), None)
        if session.reader_task:
            session.reader_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await session.reader_task
        if session.process.returncode is None:
            session.process.terminate()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(session.process.wait(), timeout=3.0)

    async def reap_idle_sessions(self) -> None:
        """Close any ACP sessions idle beyond ``idle_timeout_sec``."""
        now = asyncio.get_event_loop().time()
        expired = [
            sid
            for sid, sess in self._sessions.items()
            if (now - sess.last_used_at) > self.idle_timeout_sec and not sess.turn_lock.locked()
        ]
        for sid in expired:
            await self.close_session(sid)
