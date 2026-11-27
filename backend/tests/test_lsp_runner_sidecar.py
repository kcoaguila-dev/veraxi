"""Tests for Live LSP Sidecar in veraxi-runner and backend MCP tools (ADR-0009, Slice 4)."""

from __future__ import annotations

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from veraxi_runner.local_exec import LocalExecutor, PathConfinementError


def _lsp_frame(payload: dict) -> bytes:
    body = json.dumps(payload).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


class _FakeStreamReader:
    def __init__(self):
        self._buf = bytearray()
        self._event = asyncio.Event()
        self._closed = False

    def feed(self, data: bytes) -> None:
        self._buf.extend(data)
        self._event.set()

    def close(self) -> None:
        self._closed = True
        self._event.set()

    async def readuntil(self, separator: bytes = b"\n") -> bytes:
        while True:
            idx = self._buf.find(separator)
            if idx != -1:
                end = idx + len(separator)
                out = bytes(self._buf[:end])
                del self._buf[:end]
                return out
            if self._closed:
                raise asyncio.IncompleteReadError(bytes(self._buf), None)
            self._event.clear()
            await self._event.wait()

    async def readexactly(self, n: int) -> bytes:
        while len(self._buf) < n:
            if self._closed:
                raise asyncio.IncompleteReadError(bytes(self._buf), n)
            self._event.clear()
            await self._event.wait()
        out = bytes(self._buf[:n])
        del self._buf[:n]
        return out


class _FakeLspProcess:
    def __init__(self, file_uri: str):
        self.returncode = None
        self.stdout = _FakeStreamReader()
        self.stderr = _FakeStreamReader()
        self.stdin = MagicMock()
        self._file_uri = file_uri
        self.written: list[dict] = []

        def _write(data: bytes):
            text = data.decode("utf-8", errors="replace")
            if "\r\n\r\n" in text:
                body = text.split("\r\n\r\n", 1)[1]
                msg = json.loads(body)
                self.written.append(msg)
                req_id = msg.get("id")
                method = msg.get("method")
                if req_id is not None and method == "initialize":
                    self.stdout.feed(_lsp_frame({"jsonrpc": "2.0", "id": req_id, "result": {"capabilities": {}}}))
                elif req_id is not None and method == "textDocument/definition":
                    self.stdout.feed(
                        _lsp_frame(
                            {
                                "jsonrpc": "2.0",
                                "id": req_id,
                                "result": [
                                    {
                                        "uri": self._file_uri,
                                        "range": {
                                            "start": {"line": 4, "character": 0},
                                            "end": {"line": 4, "character": 10},
                                        },
                                    }
                                ],
                            }
                        )
                    )
                elif method == "textDocument/didOpen":
                    self.stdout.feed(
                        _lsp_frame(
                            {
                                "jsonrpc": "2.0",
                                "method": "textDocument/publishDiagnostics",
                                "params": {
                                    "uri": self._file_uri,
                                    "diagnostics": [{"message": "Unused variable", "severity": 2}],
                                },
                            }
                        )
                    )

        self.stdin.write = MagicMock(side_effect=_write)
        self.stdin.drain = AsyncMock()

    def terminate(self):
        self.returncode = 0
        self.stdout.close()

    def kill(self):
        self.returncode = -9
        self.stdout.close()

    async def wait(self):
        return 0


def test_lsp_language_mapping_and_path_confinement(tmp_path):
    from veraxi_runner.lsp_sidecar import LspSidecarManager, command_for_language, language_for_path

    assert language_for_path("src/app.py") == "python"
    assert language_for_path("lib/main.dart") == "dart"
    assert language_for_path("src/index.ts") == "typescript"
    assert language_for_path("cmd/main.go") == "go"
    assert language_for_path("src/lib.rs") == "rust"
    assert command_for_language("dart")[0] == "dart"
    assert command_for_language("python")[0] == "pyright-langserver"

    mgr = LspSidecarManager(tmp_path)
    with pytest.raises(PathConfinementError):
        mgr._resolve_file("../../etc/passwd")


@pytest.mark.asyncio
async def test_local_executor_lsp_lifecycle_and_dirty_buffer(tmp_path, monkeypatch):
    from veraxi_runner import lsp_sidecar as lsp_mod

    (tmp_path / "app.py").write_text("def hello():\n    pass\n", encoding="utf-8")
    fake_proc = _FakeLspProcess((tmp_path / "app.py").as_uri())

    async def fake_spawn(*args, **kwargs):
        return fake_proc

    monkeypatch.setattr(lsp_mod.asyncio, "create_subprocess_exec", fake_spawn)
    executor = LocalExecutor(tmp_path, runtime="direct")

    start_res = await executor.handle("lsp_start", {"path": "app.py"})
    assert start_res["language"] == "python"
    assert start_res["status"] == "running"

    req_res = await executor.handle(
        "lsp_request",
        {
            "path": "app.py",
            "method": "textDocument/definition",
            "line": 0,
            "character": 4,
            "content": "def hello():\n    return 1\n",
        },
    )
    assert isinstance(req_res["result"], list)
    assert req_res["result"][0]["range"]["start"]["line"] == 4
    methods_sent = [m.get("method") for m in fake_proc.written]
    assert "initialize" in methods_sent
    assert "textDocument/didOpen" in methods_sent

    stop_res = await executor.handle("lsp_stop", {"language": "python"})
    assert stop_res["stopped"] == 1


@pytest.mark.asyncio
async def test_ws_runner_provider_and_mcp_tools_offline_fallback(monkeypatch):
    from backend.mcp_server.tool_dispatch import execute_lsp_tool, get_tools
    from backend.sandbox.ws_runner_provider import RunnerRegistry, WsRunnerProvider

    reg = RunnerRegistry()
    provider = WsRunnerProvider({}, registry=reg)
    # Verify WsRunnerProvider exposes lsp_* methods
    assert hasattr(provider, "lsp_start")
    assert hasattr(provider, "lsp_request")
    assert hasattr(provider, "lsp_notify")
    assert hasattr(provider, "lsp_stop")

    # When offline (no runner connected), lsp_definition fails closed with SCIP/Neo4j fallback
    res = await execute_lsp_tool(
        "lsp_definition",
        {"path": "backend/app.py", "line": 10, "character": 5},
        tenant_id="t_offline",
    )
    assert res["status"] == "runner_offline"
    assert "symbol_lookup" in res["fallback_hint"]

    # When runner IS connected, get_tools includes lsp_* tools
    reg.register("t_online", MagicMock())
    monkeypatch.setattr("backend.sandbox.ws_runner_provider.GLOBAL_REGISTRY", reg)
    tools = await get_tools(tool_settings={"workspace_mode": "code"}, tenant_id="t_online")
    names = {t["function"]["name"] for t in tools if isinstance(t, dict) and "function" in t}
    assert {"lsp_definition", "lsp_references", "lsp_diagnostics"}.issubset(names)
