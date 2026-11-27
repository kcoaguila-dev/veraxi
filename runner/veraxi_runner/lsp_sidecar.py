"""Language-agnostic Live LSP Sidecar manager for ``veraxi-runner`` (ADR-0009).

Runs local language servers (``pyright-langserver``, ``dart language-server``,
``typescript-language-server``, ``gopls``, ``rust-analyzer``) on the user's
workstation — never on the hosted backend. Enforces strict
``resolve_under_repo`` path confinement and ``scrubbed_env`` allowlist.
"""

from __future__ import annotations

import asyncio
import json
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from veraxi_runner.local_exec import resolve_under_repo, scrubbed_env

_EXT_TO_LANGUAGE: dict[str, str] = {
    ".py": "python",
    ".dart": "dart",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".js": "typescript",
    ".jsx": "typescript",
    ".go": "go",
    ".rs": "rust",
}

_LANGUAGE_COMMANDS: dict[str, list[str]] = {
    "python": ["pyright-langserver", "--stdio"],
    "dart": ["dart", "language-server", "--protocol=lsp"],
    "typescript": ["typescript-language-server", "--stdio"],
    "go": ["gopls"],
    "rust": ["rust-analyzer"],
}


def language_for_path(path: str | Path) -> str:
    """Map a file extension to its LSP language key."""
    suffix = Path(path).suffix.lower()
    lang = _EXT_TO_LANGUAGE.get(suffix)
    if not lang:
        raise ValueError(f"Unsupported LSP file extension for {path!r}")
    return lang


def command_for_language(language: str) -> list[str]:
    """Return the local LSP server argv for ``language``."""
    cmd = _LANGUAGE_COMMANDS.get(language)
    if not cmd:
        raise ValueError(f"Unsupported LSP language {language!r}")
    return list(cmd)


def _encode_lsp_message(payload: dict[str, Any]) -> bytes:
    body = json.dumps(payload).encode("utf-8")
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
    return header + body


async def _read_lsp_message(stdout: asyncio.StreamReader) -> dict[str, Any]:
    content_length = 0
    while True:
        line = await stdout.readuntil(b"\n")
        stripped = line.decode("ascii", errors="replace").strip()
        if not stripped:
            break
        if stripped.lower().startswith("content-length:"):
            content_length = int(stripped.split(":", 1)[1].strip())
    if content_length <= 0:
        raise EOFError("Missing or zero Content-Length from LSP server")
    body = await stdout.readexactly(content_length)
    return json.loads(body.decode("utf-8"))


@dataclass
class _LspSession:
    language: str
    proc: asyncio.subprocess.Process
    last_used: float = field(default_factory=time.monotonic)
    next_id: int = 1
    opened_versions: dict[str, int] = field(default_factory=dict)
    diagnostics: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    pending: dict[int, asyncio.Future[dict[str, Any]]] = field(default_factory=dict)
    reader_task: asyncio.Task[None] | None = None

    def touch(self) -> None:
        self.last_used = time.monotonic()


class LspSidecarManager:
    """Persistent LSP subprocess pool keyed by ``(repo_root, language)``."""

    def __init__(self, repo: str | Path, idle_ttl_sec: float = 600.0):
        self.repo = Path(repo).resolve()
        self.idle_ttl_sec = idle_ttl_sec
        self._sessions: dict[tuple[Path, str], _LspSession] = {}
        self._lock = asyncio.Lock()

    def _resolve_file(self, path: str | Path) -> Path:
        return resolve_under_repo(self.repo, path)

    def _resolve_language(self, language: str | None, path: str | None) -> str:
        if language:
            if language not in _LANGUAGE_COMMANDS:
                raise ValueError(f"Unsupported LSP language {language!r}")
            return language
        if path:
            return language_for_path(path)
        raise ValueError("Provide either 'language' or 'path'")

    async def _reader_loop(self, session: _LspSession) -> None:
        assert session.proc.stdout is not None
        try:
            while True:
                msg = await _read_lsp_message(session.proc.stdout)
                msg_id = msg.get("id")
                if msg_id is not None and int(msg_id) in session.pending:
                    fut = session.pending.pop(int(msg_id))
                    if not fut.done():
                        fut.set_result(msg)
                elif msg.get("method") == "textDocument/publishDiagnostics":
                    params = msg.get("params") or {}
                    uri = str(params.get("uri") or "")
                    diags = params.get("diagnostics") or []
                    if uri:
                        session.diagnostics[uri] = list(diags)
        except (asyncio.IncompleteReadError, EOFError, asyncio.CancelledError):
            pass
        finally:
            for fut in session.pending.values():
                if not fut.done():
                    fut.set_exception(RuntimeError("LSP server exited"))
            session.pending.clear()

    async def _send(self, session: _LspSession, payload: dict[str, Any]) -> None:
        assert session.proc.stdin is not None
        session.proc.stdin.write(_encode_lsp_message(payload))
        await session.proc.stdin.drain()
        session.touch()

    async def _rpc(
        self, session: _LspSession, method: str, params: dict[str, Any], timeout: float = 15.0
    ) -> Any:
        req_id = session.next_id
        session.next_id += 1
        loop = asyncio.get_running_loop()
        fut: asyncio.Future[dict[str, Any]] = loop.create_future()
        session.pending[req_id] = fut
        await self._send(session, {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        msg = await asyncio.wait_for(fut, timeout=timeout)
        if "error" in msg and msg["error"] is not None:
            raise RuntimeError(f"LSP error: {msg['error']}")
        return msg.get("result")

    async def start(self, *, language: str | None = None, path: str | None = None) -> dict[str, Any]:
        if path:
            self._resolve_file(path)
        lang = self._resolve_language(language, path)
        await self.reap_idle()
        key = (self.repo, lang)
        async with self._lock:
            existing = self._sessions.get(key)
            if existing is not None and existing.proc.returncode is None:
                existing.touch()
                return {"language": lang, "status": "running", "pid": getattr(existing.proc, "pid", None)}

            cmd = command_for_language(lang)
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=str(self.repo),
                env=scrubbed_env(),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            session = _LspSession(language=lang, proc=proc)
            session.reader_task = asyncio.create_task(self._reader_loop(session))
            self._sessions[key] = session

        init_params: dict[str, Any] = {
            "processId": None,
            "rootUri": self.repo.as_uri(),
            "capabilities": {},
        }
        if lang == "typescript":
            tsc_bin = shutil.which("tsc")
            if tsc_bin:
                tsserver_js = Path(tsc_bin).resolve().parent.parent / "lib" / "tsserver.js"
                if tsserver_js.is_file():
                    init_params["initializationOptions"] = {"tsserver": {"path": str(tsserver_js)}}
        await self._rpc(session, "initialize", init_params)
        await self._send(session, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
        return {"language": lang, "status": "running", "pid": getattr(proc, "pid", None)}

    async def _sync_document(
        self, session: _LspSession, file_path: Path, content: str | None
    ) -> str:
        uri = file_path.as_uri()
        text = content if content is not None else file_path.read_text(encoding="utf-8", errors="replace")
        version = session.opened_versions.get(uri)
        if version is None:
            session.opened_versions[uri] = 1
            await self._send(
                session,
                {
                    "jsonrpc": "2.0",
                    "method": "textDocument/didOpen",
                    "params": {
                        "textDocument": {
                            "uri": uri,
                            "languageId": session.language,
                            "version": 1,
                            "text": text,
                        }
                    },
                },
            )
        elif content is not None:
            next_v = version + 1
            session.opened_versions[uri] = next_v
            await self._send(
                session,
                {
                    "jsonrpc": "2.0",
                    "method": "textDocument/didChange",
                    "params": {
                        "textDocument": {"uri": uri, "version": next_v},
                        "contentChanges": [{"text": text}],
                    },
                },
            )
        return uri

    async def request(
        self,
        *,
        path: str,
        method: str,
        line: int | None = None,
        character: int | None = None,
        content: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        resolved = self._resolve_file(path)
        lang = language_for_path(resolved)
        await self.start(language=lang, path=path)
        session = self._sessions[(self.repo, lang)]
        uri = await self._sync_document(session, resolved, content)

        if method == "textDocument/publishDiagnostics":
            await asyncio.sleep(0.05)
            return {"uri": uri, "diagnostics": session.diagnostics.get(uri, [])}

        req_params = dict(params or {})
        req_params.setdefault("textDocument", {"uri": uri})
        if line is not None and character is not None:
            req_params.setdefault("position", {"line": int(line), "character": int(character)})
        if method == "textDocument/references":
            req_params.setdefault("context", {"includeDeclaration": True})
        result = await self._rpc(session, method, req_params)
        return {"uri": uri, "result": result}

    async def notify(self, *, path: str, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        resolved = self._resolve_file(path)
        lang = language_for_path(resolved)
        await self.start(language=lang, path=path)
        session = self._sessions[(self.repo, lang)]
        await self._send(session, {"jsonrpc": "2.0", "method": method, "params": params or {}})
        return {"ok": True}

    async def stop(self, language: str | None = None) -> dict[str, Any]:
        stopped = 0
        keys = [k for k in list(self._sessions) if language is None or k[1] == language]
        for key in keys:
            session = self._sessions.pop(key, None)
            if session is None:
                continue
            if session.reader_task is not None:
                session.reader_task.cancel()
            if session.proc.returncode is None:
                session.proc.terminate()
                try:
                    await asyncio.wait_for(session.proc.wait(), timeout=2.0)
                except TimeoutError:
                    session.proc.kill()
            stopped += 1
        return {"stopped": stopped}

    async def reap_idle(self) -> int:
        now = time.monotonic()
        reaped = 0
        for key, session in list(self._sessions.items()):
            if now - session.last_used > self.idle_ttl_sec:
                await self.stop(language=key[1])
                reaped += 1
        return reaped
