"""ACP (Agent Client Protocol) JSON-RPC 2.0 framing and Veraxi SSE adapter.

Pure, zero-I/O protocol helpers translating between ACP NDJSON messages
(used by ``agy acp`` and compatible agents) and Veraxi's existing SSE
event vocabulary (``on_chat_model_stream``, ``on_reasoning_stream``,
``on_tool_start``, ``on_tool_end``, ``acp_permission_request``).
"""

from __future__ import annotations

import json
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

_QUOTA_ERROR_MARKERS = (
    "429",
    "resource_exhausted",
    "quota",
    "rate limit",
    "ratelimit",
    "too many requests",
    "usage limit",
)


def is_quota_exhausted_error(message: str) -> bool:
    """Return True if an error message indicates provider quota or rate exhaustion."""
    lowered = message.lower()
    return any(marker in lowered for marker in _QUOTA_ERROR_MARKERS)


def build_friendly_acp_error(message: str, code: int | str | None = None) -> dict[str, Any]:
    """Build a structured Veraxi SSE error payload with actionable recovery metadata."""
    if is_quota_exhausted_error(message) or code == 429:
        return {
            "error": (
                "Antigravity quota or rate limit reached. "
                "Switch to a BYOK model or try again after your quota window resets."
            ),
            "code": "quota_exhausted",
            "recoverable_action": "switch_model",
        }
    return {
        "error": message or "External ACP agent failed.",
        "code": str(code) if code is not None else "acp_error",
    }


def encode_rpc_request(
    request_id: str,
    method: str,
    params: dict[str, Any] | None = None,
) -> bytes:
    """Serialize a JSON-RPC 2.0 request as a single NDJSON line."""
    payload: dict[str, Any] = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
    }
    if params is not None:
        payload["params"] = params
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")


def encode_rpc_response(
    request_id: str | int,
    result: dict[str, Any] | None = None,
    error: dict[str, Any] | None = None,
) -> bytes:
    """Serialize a JSON-RPC 2.0 response to a server-initiated request."""
    payload: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id}
    if error is not None:
        payload["error"] = error
    else:
        payload["result"] = result if result is not None else {}
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")


def parse_ndjson_line(raw_line: str | bytes) -> dict[str, Any] | None:
    """Parse one NDJSON line into a dict, returning None for blanks or invalid JSON."""
    text = raw_line.decode("utf-8", errors="replace") if isinstance(raw_line, bytes) else raw_line
    stripped = text.strip()
    if not stripped:
        return None
    try:
        parsed = json.loads(stripped)
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def build_initialize_params(client_name: str = "veraxi", client_version: str = "1.0.0") -> dict[str, Any]:
    """Construct the ACP ``initialize`` handshake payload."""
    return {
        "protocolVersion": 1,
        "clientInfo": {"name": client_name, "version": client_version},
        "capabilities": {
            "fs": {"readTextFile": False, "writeTextFile": False},
            "terminal": False,
        },
    }


def build_session_new_params(
    cwd: str,
    mcp_servers: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Construct the ACP ``session/new`` payload."""
    return {
        "cwd": cwd,
        "mcpServers": mcp_servers or [],
    }


def build_session_prompt_params(acp_session_id: str, prompt_text: str) -> dict[str, Any]:
    """Construct the ACP ``session/prompt`` payload."""
    return {
        "sessionId": acp_session_id,
        "prompt": [{"type": "text", "text": prompt_text}],
    }


@dataclass
class AcpTurnAdapter:
    """Translates ACP notifications/requests for one turn into Veraxi SSE events."""

    veraxi_session_id: str
    step: int = 1
    reasoning_started_at: float | None = None
    tool_start_times: dict[str, float] = field(default_factory=dict)
    tool_names: dict[str, str] = field(default_factory=dict)

    def _close_reasoning_if_open(self) -> list[dict[str, Any]]:
        if self.reasoning_started_at is None:
            return []
        elapsed = round(max(0.0, time.perf_counter() - self.reasoning_started_at), 2)
        self.reasoning_started_at = None
        return [{"event": "on_reasoning_end", "data": {"seconds": elapsed}}]

    def translate_notification(self, message: dict[str, Any]) -> list[dict[str, Any]]:
        """Convert an inbound ACP JSON-RPC notification into Veraxi SSE events."""
        method = message.get("method")
        if method == "session/update":
            params = message.get("params") or {}
            update = params.get("update") if isinstance(params.get("update"), dict) else params
            return self._translate_session_update(update)
        return []

    def _translate_session_update(self, update: dict[str, Any]) -> list[dict[str, Any]]:
        kind = update.get("sessionUpdate") or update.get("type") or ""
        if kind == "agent_thought_chunk":
            return self._handle_thought_chunk(update)
        if kind == "agent_message_chunk":
            return self._handle_message_chunk(update)
        if kind == "tool_call":
            return self._handle_tool_start(update)
        if kind == "tool_call_update":
            return self._handle_tool_update(update)
        return []

    def _extract_text(self, update: dict[str, Any]) -> str:
        content = update.get("content")
        if isinstance(content, dict):
            return str(content.get("text") or "")
        if isinstance(content, str):
            return content
        return str(update.get("text") or "")

    def _handle_thought_chunk(self, update: dict[str, Any]) -> list[dict[str, Any]]:
        text = self._extract_text(update)
        if not text:
            return []
        if self.reasoning_started_at is None:
            self.reasoning_started_at = time.perf_counter()
        return [{"event": "on_reasoning_stream", "data": {"text": text}}]

    def _handle_message_chunk(self, update: dict[str, Any]) -> list[dict[str, Any]]:
        text = self._extract_text(update)
        if not text:
            return []
        events = self._close_reasoning_if_open()
        events.append({"event": "on_chat_model_stream", "data": {"chunk": {"content": text}}})
        return events

    def _handle_tool_start(self, update: dict[str, Any]) -> list[dict[str, Any]]:
        events = self._close_reasoning_if_open()
        run_id = str(update.get("toolCallId") or uuid.uuid4())
        name = str(update.get("title") or update.get("kind") or update.get("name") or "tool")
        raw_input = update.get("rawInput") or update.get("input") or {}
        self.tool_start_times[run_id] = time.perf_counter()
        self.tool_names[run_id] = name
        events.append(
            {
                "event": "on_tool_start",
                "name": name,
                "label": name,
                "step": self.step,
                "run_id": run_id,
                "data": {"input": raw_input if isinstance(raw_input, dict) else {"value": raw_input}},
            }
        )
        return events

    def _handle_tool_update(self, update: dict[str, Any]) -> list[dict[str, Any]]:
        status = str(update.get("status") or "").lower()
        if status not in ("completed", "failed", "error", "cancelled"):
            return []
        run_id = str(update.get("toolCallId") or "")
        start_t = self.tool_start_times.pop(run_id, None)
        duration_ms = round((time.perf_counter() - start_t) * 1000) if start_t is not None else None
        name = self.tool_names.pop(run_id, str(update.get("title") or "tool"))
        raw_output = update.get("rawOutput") or update.get("output") or ""
        output_str = json.dumps(raw_output) if isinstance(raw_output, (dict, list)) else str(raw_output)
        is_err = status in ("failed", "error", "cancelled")
        return [
            {
                "event": "on_tool_end",
                "name": name,
                "label": name,
                "step": self.step,
                "run_id": run_id or str(uuid.uuid4()),
                "duration_ms": duration_ms,
                "status": "error" if is_err else "success",
                "summary": output_str[:120] if output_str else ("Tool failed" if is_err else "Executed successfully"),
                "data": {"output": output_str},
            }
        ]

    def translate_permission_request(self, message: dict[str, Any]) -> dict[str, Any]:
        """Convert an inbound ``session/request_permission`` RPC into an SSE event."""
        params = message.get("params") or {}
        tool_call = params.get("toolCall") if isinstance(params.get("toolCall"), dict) else {}
        return {
            "event": "acp_permission_request",
            "session_id": self.veraxi_session_id,
            "request_id": str(message.get("id")),
            "tool_name": str(tool_call.get("title") or tool_call.get("kind") or "tool"),
            "description": str(params.get("description") or tool_call.get("title") or "Permission requested"),
            "args": tool_call.get("rawInput") if isinstance(tool_call.get("rawInput"), dict) else {},
            "options": params.get("options") or [],
        }

    def finalize_turn(self) -> list[dict[str, Any]]:
        """Flush any open reasoning timer at the end of a prompt turn."""
        return self._close_reasoning_if_open()
