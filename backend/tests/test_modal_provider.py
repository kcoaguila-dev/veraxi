"""Tests for the Modal and E2B providers with fake SDK modules."""

import sys
import types
from typing import ClassVar

import pytest

from backend.sandbox.base import SandboxError
from backend.sandbox.e2b_provider import E2BProvider
from backend.sandbox.modal_provider import ModalProvider


# -- Fake Modal SDK ------------------------------------------------------
class _FakeImage:
    @classmethod
    def debian_slim(cls):
        return cls()


class _FakeProc:
    def __init__(self):
        self.stdout = ["Linux fake 6.0\n", "git version 2.43\n"]
        self.stderr = []
        self.returncode = 0

    def wait(self):
        return 0


class _FakeModalSandbox:
    create_kwargs: ClassVar[dict] = {}
    instances: ClassVar[list] = []

    def __init__(self):
        self.object_id = "modal-sbx-1"
        self.exec_calls = []
        _FakeModalSandbox.instances.append(self)

    @classmethod
    def create(cls, **kwargs):
        cls.create_kwargs = kwargs
        return cls()

    def exec(self, *args):
        self.exec_calls.append(args)
        return _FakeProc()

    def terminate(self):
        self.terminated = True


@pytest.fixture()
def fake_modal(monkeypatch):
    _FakeModalSandbox.create_kwargs = {}
    _FakeModalSandbox.instances = []
    module = types.ModuleType("modal")
    module.Image = _FakeImage
    module.Sandbox = _FakeModalSandbox
    monkeypatch.setitem(sys.modules, "modal", module)
    return module


def _settings(**overrides):
    base = {
        "provider": "modal", "base_image": "polyglot", "cpu_cores": 4,
        "memory_mb": 8192, "max_session_sec": 1800, "egress_mode": "allowlist",
        "isolate_git_branch": True, "config": {},
    }
    base.update(overrides)
    return base


class TestModalProvider:
    @pytest.mark.asyncio
    async def test_create_enforces_resources_and_network(self, fake_modal):
        provider = ModalProvider(
            _settings(egress_mode="offline"),
            {"modal_token_id": "tok-id-secret", "modal_token_secret": "tok-secret-value"},
        )
        info = await provider.start_session("tenant-1")
        assert info.status == "running"
        kwargs = _FakeModalSandbox.create_kwargs
        assert kwargs["cpu"] == 4.0
        assert kwargs["memory"] == 8192
        assert kwargs["timeout"] == 1800
        assert kwargs["block_network"] is True

    @pytest.mark.asyncio
    async def test_secrets_never_in_sandbox_env(self, fake_modal):
        provider = ModalProvider(
            _settings(),
            {"modal_token_id": "tok-id-secret", "modal_token_secret": "tok-secret-value"},
        )
        await provider.start_session("tenant-1")
        kwargs = _FakeModalSandbox.create_kwargs
        env = kwargs.get("env") or {}
        assert "tok-id-secret" not in str(env)
        assert "tok-secret-value" not in str(env)
        assert "tok-secret-value" not in str(kwargs)

    @pytest.mark.asyncio
    async def test_network_allowed_when_not_offline(self, fake_modal):
        provider = ModalProvider(_settings(egress_mode="allowlist"), {"modal_token_id": "i", "modal_token_secret": "s"})
        await provider.start_session("tenant-1")
        assert _FakeModalSandbox.create_kwargs["block_network"] is False

    @pytest.mark.asyncio
    async def test_missing_credentials_fail_closed(self, fake_modal):
        provider = ModalProvider(_settings(), {})
        with pytest.raises(SandboxError):
            await provider.start_session("tenant-1")

    @pytest.mark.asyncio
    async def test_exec_streams_events(self, fake_modal):
        provider = ModalProvider(_settings(), {"modal_token_id": "i", "modal_token_secret": "s"})
        info = await provider.start_session("tenant-1")
        events = [e async for e in provider.exec_command(info.session_id, "uname -a")]
        kinds = [e.kind for e in events]
        assert kinds[-1] == "exit"
        assert events[-1].exit_code == 0
        assert any("Linux" in e.data for e in events if e.kind == "stdout")

    @pytest.mark.asyncio
    async def test_stop_terminates(self, fake_modal):
        provider = ModalProvider(_settings(), {"modal_token_id": "i", "modal_token_secret": "s"})
        info = await provider.start_session("tenant-1")
        await provider.stop_session(info.session_id)
        assert _FakeModalSandbox.instances[0].terminated is True


# -- Fake E2B SDK ----------------------------------------------------------
class _FakeCommands:
    def run(self, cmd, timeout=None):
        return types.SimpleNamespace(stdout="ok\n", stderr="", exit_code=0)


class _FakeFiles:
    def __init__(self):
        self.store = {}

    def read(self, path):
        return self.store.get(path, "")

    def write(self, path, content):
        self.store[path] = content


class _FakeE2BSandbox:
    create_kwargs: ClassVar[dict] = {}
    instances: ClassVar[list] = []

    def __init__(self):
        self.sandbox_id = "e2b-sbx-1"
        self.commands = _FakeCommands()
        self.files = _FakeFiles()
        self.paused = False
        self.killed = False
        _FakeE2BSandbox.instances.append(self)

    @classmethod
    def create(cls, **kwargs):
        cls.create_kwargs = kwargs
        return cls()

    @classmethod
    def resume(cls, sandbox_id, api_key=None):
        inst = cls()
        inst.sandbox_id = sandbox_id
        return inst

    def pause(self):
        self.paused = True

    def kill(self):
        self.killed = True


@pytest.fixture()
def fake_e2b(monkeypatch):
    _FakeE2BSandbox.create_kwargs = {}
    _FakeE2BSandbox.instances = []
    module = types.ModuleType("e2b")
    module.Sandbox = _FakeE2BSandbox
    monkeypatch.setitem(sys.modules, "e2b", module)
    return module


class TestE2BProvider:
    @pytest.mark.asyncio
    async def test_create_enforces_resources_network_and_key(self, fake_e2b):
        provider = E2BProvider(
            _settings(provider="e2b", egress_mode="offline"),
            {"e2b_api_key": "e2b-secret-key"},
        )
        info = await provider.start_session("tenant-1")
        kwargs = _FakeE2BSandbox.create_kwargs
        assert kwargs["api_key"] == "e2b-secret-key"
        assert kwargs["cpu_count"] == 4
        assert kwargs["memory_mb"] == 8192
        assert kwargs["allow_internet_access"] is False
        assert "e2b-secret-key" not in str(kwargs.get("envs") or {})
        assert info.external_sandbox_id == "e2b-sbx-1"

    @pytest.mark.asyncio
    async def test_exec_and_files(self, fake_e2b):
        provider = E2BProvider(_settings(provider="e2b"), {"e2b_api_key": "k"})
        info = await provider.start_session("tenant-1")
        events = [e async for e in provider.exec_command(info.session_id, "ls")]
        assert events[-1].exit_code == 0
        await provider.write_file(info.session_id, "a.txt", "hello")
        assert await provider.read_file(info.session_id, "a.txt") == "hello"

    @pytest.mark.asyncio
    async def test_pause_and_resume(self, fake_e2b):
        provider = E2BProvider(_settings(provider="e2b"), {"e2b_api_key": "k"})
        info = await provider.start_session("tenant-1")
        await provider.pause_session(info.session_id)
        assert _FakeE2BSandbox.instances[0].paused is True
        assert provider._infos[info.session_id].status == "paused"
        await provider.resume_session(info.session_id)
        assert provider._infos[info.session_id].status == "running"
