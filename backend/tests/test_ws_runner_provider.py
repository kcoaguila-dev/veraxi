"""Tests for the WS runner provider, runner local_exec, and docker argv."""

import asyncio
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "runner"))

from backend.sandbox.base import SandboxError
from backend.sandbox.ws_runner_provider import RunnerRegistry, WsRunnerProvider
from veraxi_runner.local_exec import (
    LocalExecutor,
    PathConfinementError,
    build_docker_command,
    resolve_under_repo,
    scrubbed_env,
)


class FakeWebSocket:
    """Captures sent JSON-RPC requests; tests feed replies manually."""

    def __init__(self):
        self.sent: list[dict] = []

    async def send_text(self, text: str):
        self.sent.append(json.loads(text))


@pytest.fixture()
def registry_with_ws():
    registry = RunnerRegistry()
    ws = FakeWebSocket()
    registry.register("tenant-1", ws)
    return registry, ws


def _provider(registry):
    return WsRunnerProvider({"provider": "local_runner", "config": {}}, {}, registry=registry)


class TestWsRunnerProvider:
    @pytest.mark.asyncio
    async def test_exec_streams_events(self, registry_with_ws):
        registry, ws = registry_with_ws
        provider = _provider(registry)
        info = await provider.start_session("tenant-1")

        async def collect():
            return [e async for e in provider.exec_command(info.session_id, "ls")]

        task = asyncio.create_task(collect())
        await asyncio.sleep(0.05)
        assert ws.sent and ws.sent[0]["method"] == "exec"
        request_id = ws.sent[0]["id"]
        await provider.handle_message("tenant-1", json.dumps(
            {"id": request_id, "result": {"type": "stdout", "data": "hello\n"}}
        ))
        await provider.handle_message("tenant-1", json.dumps(
            {"id": request_id, "result": {"type": "stderr", "data": "warn\n"}}
        ))
        await provider.handle_message("tenant-1", json.dumps(
            {"id": request_id, "result": {"type": "exit", "exit_code": 3}}
        ))
        events = await asyncio.wait_for(task, timeout=5)
        assert [(e.kind, e.data) for e in events[:2]] == [("stdout", "hello\n"), ("stderr", "warn\n")]
        assert events[-1].kind == "exit" and events[-1].exit_code == 3

    @pytest.mark.asyncio
    async def test_read_write_diff_round_trip(self, registry_with_ws):
        registry, ws = registry_with_ws
        provider = _provider(registry)
        info = await provider.start_session("tenant-1")

        async def respond_next(result):
            await asyncio.sleep(0.05)
            request = ws.sent[-1]
            await provider.handle_message(
                "tenant-1", json.dumps({"id": request["id"], "result": result})
            )

        task = asyncio.create_task(provider.read_file(info.session_id, "a.txt"))
        await respond_next({"content": "data!"})
        assert await asyncio.wait_for(task, timeout=5) == "data!"

        task = asyncio.create_task(provider.get_diff(info.session_id))
        await respond_next({"diff": "diff-text"})
        assert await asyncio.wait_for(task, timeout=5) == "diff-text"

    @pytest.mark.asyncio
    async def test_start_without_runner_fails(self):
        provider = _provider(RunnerRegistry())
        with pytest.raises(SandboxError):
            await provider.start_session("tenant-1")

    @pytest.mark.asyncio
    async def test_request_timeout_fails_closed(self, registry_with_ws):
        registry, _ws = registry_with_ws
        provider = _provider(registry)
        provider._request_timeout = 0.1
        info = await provider.start_session("tenant-1")
        with pytest.raises(SandboxError):
            await provider.read_file(info.session_id, "a.txt")


class TestLocalExec:
    def test_path_confinement_allows_inside(self, tmp_path):
        assert resolve_under_repo(tmp_path, "sub/file.txt") == (tmp_path / "sub/file.txt").resolve()

    @pytest.mark.parametrize("bad", ["../escape.txt", "../../etc/passwd", "/etc/passwd"])
    def test_path_confinement_rejects_traversal(self, tmp_path, bad):
        with pytest.raises(PathConfinementError):
            resolve_under_repo(tmp_path, bad)

    @pytest.mark.asyncio
    async def test_direct_exec_and_files_confined(self, tmp_path):
        executor = LocalExecutor(tmp_path, runtime="direct")
        result = await executor.handle("exec", {"command": "echo hello-from-runner"})
        assert "hello-from-runner" in result["stdout"]
        assert result["exit_code"] == 0
        await executor.handle("write_file", {"path": "note.txt", "content": "abc"})
        assert (tmp_path / "note.txt").read_text() == "abc"
        read = await executor.handle("read_file", {"path": "note.txt"})
        assert read == {"content": "abc"}
        with pytest.raises(PathConfinementError):
            await executor.handle("read_file", {"path": "../secret.txt"})

    def test_scrubbed_env_excludes_secrets(self, monkeypatch):
        monkeypatch.setenv("SOME_API_SECRET", "do-not-leak")
        monkeypatch.setenv("PATH", "/usr/bin")
        env = scrubbed_env()
        assert "SOME_API_SECRET" not in env
        assert env["PATH"] == "/usr/bin"

    def test_docker_argv_hardening(self, tmp_path):
        argv = build_docker_command(tmp_path, "ls", offline=True)
        assert "--cap-drop=ALL" in argv
        assert "--security-opt=no-new-privileges" in argv
        assert "--network" in argv and argv[argv.index("--network") + 1] == "none"
        mounts = [argv[i + 1] for i, a in enumerate(argv) if a == "-v"]
        assert mounts == [f"{tmp_path.resolve()}:/repo"]

    def test_docker_argv_online_has_no_network_none(self, tmp_path):
        argv = build_docker_command(tmp_path, "ls", offline=False)
        assert "--network" not in argv

    def test_microsandbox_missing_binary_is_clear_error(self, tmp_path, monkeypatch):
        import shutil

        monkeypatch.setattr(shutil, "which", lambda _name: None)
        executor = LocalExecutor(tmp_path, runtime="microsandbox")
        with pytest.raises(RuntimeError, match="microsandbox"):
            executor._argv_for("ls")
