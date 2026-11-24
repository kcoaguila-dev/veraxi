"""Outbound-WebSocket ACP transport via ``veraxi-runner``.

Allows cloud/remote Veraxi deployments to drive ``agy acp`` running on
the user's own workstation over the existing outbound WebSocket tunnel
(``GLOBAL_REGISTRY`` in ``ws_runner_provider.py``), preserving the local
trust boundary with zero inbound ports and zero OAuth token uploads.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from collections.abc import AsyncGenerator
from typing import Any

import sentry_sdk

from backend.acp.protocol import AcpTurnAdapter, build_friendly_acp_error
from backend.sandbox.ws_runner_provider import GLOBAL_REGISTRY, RunnerRegistry

logger = logging.getLogger(__name__)


class RunnerAcpTransport:
    """Streams ACP turns through a tenant's connected ``veraxi-runner``."""

    def __init__(self, registry: RunnerRegistry | None = None):
        self.registry = registry or GLOBAL_REGISTRY
        self._streams: dict[str, asyncio.Queue[dict[str, Any]]] = {}
        self._thread_sessions: dict[tuple[str, str], str] = {}

    def is_connected(self, tenant_id: str) -> bool:
        return self.registry.is_connected(tenant_id)

    async def handle_runner_acp_event(self, raw_message: dict[str, Any]) -> bool:
        """Route an inbound ``acp_event`` message from ``veraxi-runner`` to its queue."""
        request_id = str(raw_message.get("id") or "")
        queue = self._streams.get(request_id)
        if queue is None:
            return False
        await queue.put(raw_message)
        return True

    async def _send_jsonrpc(self, tenant_id: str, payload: dict[str, Any]) -> None:
        ws = self.registry.get(tenant_id)
        if ws is None:
            raise RuntimeError("No veraxi-runner is connected for this tenant")
        text = json.dumps(payload)
        send_text = getattr(ws, "send_text", None)
        if callable(send_text):
            res = send_text(text)
            if asyncio.iscoroutine(res):
                await res
            return
        send = getattr(ws, "send", None)
        if callable(send):
            res = send(text)
            if asyncio.iscoroutine(res):
                await res
            return
        raise RuntimeError("Connected runner websocket does not support sending")

    async def resolve_permission(
        self, tenant_id: str, veraxi_session_id: str, request_id: str, outcome: str
    ) -> bool:
        if not self.is_connected(tenant_id):
            return False
        await self._send_jsonrpc(
            tenant_id,
            {
                "jsonrpc": "2.0",
                "id": uuid.uuid4().hex,
                "method": "acp.permission",
                "params": {
                    "session_id": veraxi_session_id,
                    "request_id": request_id,
                    "outcome": outcome,
                },
            },
        )
        return True

    async def cancel_session_turn(self, tenant_id: str, veraxi_session_id: str) -> bool:
        if not self.is_connected(tenant_id):
            return False
        await self._send_jsonrpc(
            tenant_id,
            {
                "jsonrpc": "2.0",
                "id": uuid.uuid4().hex,
                "method": "acp.cancel",
                "params": {"session_id": veraxi_session_id},
            },
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
        session_id = self._thread_sessions.setdefault((tenant_id, thread_id), uuid.uuid4().hex)
        req_id = uuid.uuid4().hex
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._streams[req_id] = queue
        adapter = AcpTurnAdapter(veraxi_session_id=session_id)

        yield {
            "event": "on_step_start",
            "step": 1,
            "name": "Antigravity ACP (Runner)",
            "description": "Running via local veraxi-runner bridge (user quota)...",
        }

        try:
            await self._send_jsonrpc(
                tenant_id,
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "acp.prompt",
                    "params": {
                        "session_id": session_id,
                        "thread_id": thread_id,
                        "prompt": prompt_text,
                        "cwd": cwd,
                        "mcp_servers": mcp_servers or [],
                    },
                },
            )
            while True:
                msg = await asyncio.wait_for(queue.get(), timeout=300.0)
                if msg.get("error"):
                    yield build_friendly_acp_error(str(msg["error"]))
                    break
                result = msg.get("result") or {}
                if result.get("done"):
                    break
                acp_msg = result.get("acp_message")
                if not isinstance(acp_msg, dict):
                    continue
                if acp_msg.get("method") == "session/request_permission":
                    yield adapter.translate_permission_request(acp_msg)
                    continue
                for evt in adapter.translate_notification(acp_msg):
                    yield evt
            for evt in adapter.finalize_turn():
                yield evt
        except TimeoutError:
            yield build_friendly_acp_error("Runner ACP turn timed out")
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            yield build_friendly_acp_error(str(exc))
        finally:
            self._streams.pop(req_id, None)
