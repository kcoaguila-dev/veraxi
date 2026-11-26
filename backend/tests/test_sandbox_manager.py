"""Tests for the sandbox store, manager, policy, and tool gating."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest

from backend.sandbox.base import ExecEvent, SandboxError, SandboxProvider, SandboxSessionInfo
from backend.sandbox.manager import SandboxManager
from backend.sandbox.policy import (
    classify_command,
    is_plan_blocked,
    plan_mode_block,
    requires_approval,
)
from backend.security.token_vault import decrypt_secrets
from backend.services import sandbox_store as store


# -- Fake Supabase (multi-table) ---------------------------------------
class _FakeResponse:
    def __init__(self, data):
        self.data = data


class _FakeQuery:
    def __init__(self, table):
        self._table = table
        self._filters = {}
        self._mode = "select"
        self._payload = None

    def select(self, *_a, **_k):
        self._mode = "select"
        return self

    def insert(self, payload):
        self._mode = "insert"
        self._payload = payload
        return self

    def update(self, payload):
        self._mode = "update"
        self._payload = payload
        return self

    def delete(self):
        self._mode = "delete"
        return self

    def eq(self, column, value):
        self._filters[column] = value
        return self

    def order(self, *_a, **_k):
        return self

    def _matches(self, row):
        return all(row.get(k) == v for k, v in self._filters.items())

    def execute(self):
        if self._mode == "insert":
            row = dict(self._payload or {})
            row.setdefault("id", str(uuid.uuid4()))
            row.setdefault("created_at", "2026-01-01T00:00:00Z")
            row.setdefault("updated_at", "2026-01-01T00:00:00Z")
            self._table.rows.append(row)
            return _FakeResponse([row])
        if self._mode == "update":
            updated = []
            for row in self._table.rows:
                if self._matches(row):
                    row.update(self._payload or {})
                    updated.append(row)
            return _FakeResponse(updated)
        if self._mode == "delete":
            kept, removed = [], []
            for row in self._table.rows:
                (removed if self._matches(row) else kept).append(row)
            self._table.rows = kept
            return _FakeResponse(removed)
        return _FakeResponse([r for r in self._table.rows if self._matches(r)])


class _FakeTable:
    def __init__(self):
        self.rows = []

    def select(self, *a, **k):
        return _FakeQuery(self).select(*a, **k)

    def insert(self, payload):
        return _FakeQuery(self).insert(payload)

    def update(self, payload):
        return _FakeQuery(self).update(payload)

    def delete(self):
        return _FakeQuery(self).delete()


class FakeSupabase:
    def __init__(self):
        self._tables = {}

    def table(self, name):
        return self._tables.setdefault(name, _FakeTable())


@pytest.fixture(autouse=True)
def _vault_key(monkeypatch):
    monkeypatch.setenv("INTEGRATION_ENCRYPTION_KEY", "sandbox-test-key")
    from backend.config import get_config

    get_config.cache_clear()
    yield
    get_config.cache_clear()


# -- Store ---------------------------------------------------------------
class TestSandboxStore:
    def test_config_secrets_encrypted_round_trip(self):
        fake = FakeSupabase()
        row = store.upsert_config(
            fake, "tenant-1",
            {"provider": "modal", "cpu_cores": 4},
            secrets={"modal_token_id": "id-123", "modal_token_secret": "shh"},
        )
        assert row["encrypted_secrets"]
        assert "shh" not in row["encrypted_secrets"]
        assert decrypt_secrets(row["encrypted_secrets"]) == {
            "modal_token_id": "id-123", "modal_token_secret": "shh",
        }
        view = store.public_view(row)
        assert view["has_secrets"] is True
        assert "encrypted_secrets" not in view
        assert "shh" not in str(view)
        assert view["provider"] == "modal"
        assert view["cpu_cores"] == 4

    def test_upsert_updates_existing_and_preserves_secrets(self):
        fake = FakeSupabase()
        store.upsert_config(fake, "t", {"provider": "e2b"}, secrets={"e2b_api_key": "k"})
        row = store.upsert_config(fake, "t", {"provider": "modal"}, secrets=None)
        assert row["provider"] == "modal"
        assert store.decrypt_row_secrets(row) == {"e2b_api_key": "k"}
        assert len(fake.table(store.CONFIG_TABLE).rows) == 1

    def test_session_crud(self):
        fake = FakeSupabase()
        row = store.create_session(fake, "t", {"status": "running", "external_sandbox_id": "ext-1"})
        assert store.session_public_view(row)["status"] == "running"
        updated = store.update_session(fake, "t", row["id"], {"status": "paused"})
        assert updated["status"] == "paused"
        assert store.delete_session(fake, "t", row["id"]) is True
        assert store.list_sessions(fake, "t") == []

    def test_validate_config_fields(self):
        with pytest.raises(ValueError):
            store.validate_config_fields({"provider": "nope"})
        with pytest.raises(ValueError):
            store.validate_config_fields({"autonomy_mode": "yolo"})


# -- Policy ----------------------------------------------------------------
class TestPolicy:
    @pytest.mark.parametrize("cmd", [
        "ls -la", "rg foo src", "cat README.md", "git status", "git diff",
        "pytest -q", "flutter test", "python -m pytest tests/", "pwd",
    ])
    def test_read_only_classification(self, cmd):
        assert classify_command(cmd) == "read_only"

    @pytest.mark.parametrize("cmd", [
        "rm -rf build", "pip install requests", "git push origin main",
        "git commit -m x", "echo hi > out.txt", "npm install", "mv a b",
        "python script.py", "flutter build apk",
    ])
    def test_mutating_classification(self, cmd):
        assert classify_command(cmd) == "mutating"

    def test_git_push_always_requires_approval(self):
        for mode in ("ask_all", "auto_read_test", "autonomous"):
            assert requires_approval(mode, "git push origin main") is True
            assert requires_approval(mode, "ls && git push") is True

    def test_autonomy_matrix(self):
        assert requires_approval("ask_all", "ls") is True
        assert requires_approval("ask_all", None, is_write=True) is True
        assert requires_approval("auto_read_test", "ls") is False
        assert requires_approval("auto_read_test", "pytest") is False
        assert requires_approval("auto_read_test", "rm x") is True
        assert requires_approval("auto_read_test", None, is_write=True) is True
        assert requires_approval("autonomous", "rm x") is False
        assert requires_approval("autonomous", None, is_write=True) is False

    def test_auto_workspace_writes_matrix(self):
        mode = "auto_workspace_writes"
        # Reads and tests run automatically.
        assert requires_approval(mode, "ls") is False
        assert requires_approval(mode, "pytest -q") is False
        assert requires_approval(mode, "git status") is False
        # Workspace writes run automatically.
        assert requires_approval(mode, None, is_write=True) is False
        assert requires_approval(mode, "mkdir -p src/x") is False
        assert requires_approval(mode, "cp a.py b.py") is False
        assert requires_approval(mode, "echo hi > out.txt") is False
        # git add / commit inside the workspace run automatically.
        assert requires_approval(mode, "git add -A") is False
        assert requires_approval(mode, "git commit -m wip") is False
        # Installs, network, and system commands need approval.
        assert requires_approval(mode, "pip install requests") is True
        assert requires_approval(mode, "npm install") is True
        assert requires_approval(mode, "curl https://example.com") is True
        assert requires_approval(mode, "wget https://example.com/x") is True
        assert requires_approval(mode, "sudo ls") is True
        assert requires_approval(mode, "apt-get install git") is True
        # Other mutating git subcommands need approval.
        assert requires_approval(mode, "git checkout -b feat") is True
        assert requires_approval(mode, "git pull") is True
        assert requires_approval(mode, "git reset --hard") is True
        # git push ALWAYS needs approval, in this mode too.
        assert requires_approval(mode, "git push origin main") is True
        assert requires_approval(mode, "ls && git push") is True

    def test_auto_workspace_writes_is_a_valid_config_mode(self):
        store.validate_config_fields({"autonomy_mode": "auto_workspace_writes"})

    def test_plan_mode_block(self):
        block = plan_mode_block("plan", tool_name="sandbox_write_file")
        assert block is not None
        assert block["error"] == "plan_mode_blocked"
        assert block["execution_mode"] == "plan"
        assert plan_mode_block(
            "plan", tool_name="sandbox_exec", command="rm -rf build"
        )["error"] == "plan_mode_blocked"
        # Read-only work is never blocked in plan mode.
        assert plan_mode_block("plan", tool_name="sandbox_exec", command="ls") is None
        assert plan_mode_block("plan", tool_name="sandbox_read_file") is None
        # Act mode blocks nothing.
        assert plan_mode_block("act", tool_name="sandbox_write_file") is None
        assert plan_mode_block(None, tool_name="sandbox_write_file") is None
        assert is_plan_blocked("plan", is_write=True) is True
        assert is_plan_blocked("plan", command="git status") is False


# -- Manager -----------------------------------------------------------------
class FakeProvider(SandboxProvider):
    provider_name = "fake"

    def __init__(self, settings, secrets=None):
        super().__init__(settings, secrets)
        self.infos = {}
        self.stopped = []
        self.commands = []

    async def start_session(self, tenant_id, repo_url=None):
        info = SandboxSessionInfo(tenant_id=tenant_id, provider="fake", status="running")
        self.infos[info.session_id] = info
        return info

    async def exec_command(self, session_id, cmd, cwd=None, timeout_sec=120):
        self.commands.append(cmd)
        yield ExecEvent(kind="stdout", data=f"ran:{cmd}\n")
        yield ExecEvent(kind="exit", data="", exit_code=0)

    async def read_file(self, session_id, path):
        return "file-content"

    async def write_file(self, session_id, path, content):
        self.commands.append(f"write:{path}")

    async def get_diff(self, session_id):
        return "diff --git a/x b/x"

    async def stop_session(self, session_id):
        self.stopped.append(session_id)

    async def pause_session(self, session_id):
        self.infos[session_id].status = "paused"


def _manager_with_fake():
    created = []

    def factory(settings, secrets):
        provider = FakeProvider(settings, secrets)
        created.append(provider)
        return provider

    mgr = SandboxManager(provider_factory=factory)
    mgr.set_tenant_config("tenant-1", {"provider": "modal", "autonomy_mode": "auto_read_test"})
    return mgr, created


class TestManager:
    def test_provider_selection_by_name(self):
        mgr = SandboxManager()
        from backend.sandbox.e2b_provider import E2BProvider
        from backend.sandbox.modal_provider import ModalProvider
        from backend.sandbox.remote_mcp_provider import RemoteMcpProvider
        from backend.sandbox.ws_runner_provider import WsRunnerProvider

        assert isinstance(mgr.create_provider({"provider": "modal"}, {}), ModalProvider)
        assert isinstance(mgr.create_provider({"provider": "e2b"}, {}), E2BProvider)
        assert isinstance(
            mgr.create_provider({"provider": "remote_mcp", "config": {"url": "https://x.example.com"}}, {}),
            RemoteMcpProvider,
        )
        assert isinstance(mgr.create_provider({"provider": "local_runner"}, {}), WsRunnerProvider)
        with pytest.raises(SandboxError):
            mgr.create_provider({"provider": "disabled"}, {})

    @pytest.mark.asyncio
    async def test_get_or_create_reuses_chat_session(self):
        mgr, created = _manager_with_fake()
        first = await mgr.get_or_create_session("tenant-1", chat_id="chat-1")
        second = await mgr.get_or_create_session("tenant-1", chat_id="chat-1")
        assert first.session_id == second.session_id
        assert len(created) == 1
        other = await mgr.get_or_create_session("tenant-1", chat_id="chat-2")
        assert other.session_id != first.session_id

    @pytest.mark.asyncio
    async def test_idle_cleanup_stops_stale_sessions(self):
        mgr, created = _manager_with_fake()
        info = await mgr.get_or_create_session("tenant-1", chat_id="c")
        info.last_active_at = datetime.now(UTC) - timedelta(seconds=5000)
        stopped = await mgr.cleanup_idle_sessions()
        assert stopped == [info.session_id]
        assert created[0].stopped == [info.session_id]

    @pytest.mark.asyncio
    async def test_idle_cleanup_keeps_fresh_sessions(self):
        mgr, _created = _manager_with_fake()
        await mgr.get_or_create_session("tenant-1", chat_id="c")
        assert await mgr.cleanup_idle_sessions() == []

    def test_runner_token_validation(self):
        mgr = SandboxManager()
        mgr.set_tenant_config("tenant-1", {"provider": "local_runner"}, secrets={"runner_token": "tok-abc"})
        assert mgr.validate_runner_token("tenant-1", "tok-abc") is True
        assert mgr.validate_runner_token("tenant-1", "wrong") is False
        assert mgr.validate_runner_token("tenant-1", "") is False

    def test_runner_token_hash_validation(self):
        import hashlib

        mgr = SandboxManager()
        digest = hashlib.sha256(b"tok-xyz").hexdigest()
        mgr.set_tenant_config("tenant-1", {"provider": "local_runner"}, secrets={"runner_token_hash": digest})
        assert mgr.validate_runner_token("tenant-1", "tok-xyz") is True
        assert mgr.validate_runner_token("tenant-1", "tok-abc") is False


# -- Tool dispatch gating ------------------------------------------------------
class TestSandboxTools:
    @pytest.mark.asyncio
    async def test_get_tools_adds_exactly_four_when_enabled(self):
        from backend.mcp_server.tool_dispatch import get_tools

        tools = await get_tools({"sandbox_enabled": True}, tenant_id="tenant-1")
        names = [t["function"]["name"] for t in tools]
        sandbox_names = [n for n in names if n.startswith("sandbox_")]
        assert sandbox_names == [
            "sandbox_exec", "sandbox_read_file", "sandbox_write_file", "sandbox_diff",
        ]

    @pytest.mark.asyncio
    async def test_get_tools_plan_mode_removes_mutating_sandbox_tools(self):
        from backend.mcp_server.tool_dispatch import get_tools

        tools = await get_tools(
            {"sandbox_enabled": True, "execution_mode": "plan"},
            tenant_id="tenant-1",
        )
        names = [t["function"]["name"] for t in tools]
        assert "sandbox_exec" not in names
        assert "sandbox_write_file" not in names
        # Read-only sandbox tools stay available while planning.
        assert "sandbox_read_file" in names
        assert "sandbox_diff" in names

        act_tools = await get_tools(
            {"sandbox_enabled": True, "execution_mode": "act"},
            tenant_id="tenant-1",
        )
        act_names = [t["function"]["name"] for t in act_tools]
        assert "sandbox_exec" in act_names
        assert "sandbox_write_file" in act_names

    @pytest.mark.asyncio
    async def test_plan_mode_blocks_write_file_called_directly(self):
        """Adversarial: dispatch must refuse even when the caller
        bypasses the plan-filtered tool schema list entirely."""
        from backend.mcp_server.tool_dispatch import execute_tools_internal

        mgr, created = _manager_with_fake()
        _context, merged = await execute_tools_internal(
            [{"name": "sandbox_write_file", "args": {"path": "a.txt", "content": "hi"}}],
            "tenant-1",
            {
                "sandbox_enabled": True,
                "sandbox_manager": mgr,
                "execution_mode": "plan",
            },
        )
        payloads = [getattr(m, "payload", {}) for m in merged]
        blocked = [
            p for p in payloads
            if isinstance(p, dict) and p.get("error") == "plan_mode_blocked"
        ]
        assert blocked, payloads
        assert blocked[0]["tool_name"] == "sandbox_write_file"
        assert created == []  # nothing executed / no session started

    @pytest.mark.asyncio
    async def test_plan_mode_blocks_mutating_exec_but_allows_reads(self):
        from backend.mcp_server.tool_dispatch import execute_tools_internal

        mgr, created = _manager_with_fake()
        _context, merged = await execute_tools_internal(
            [{"name": "sandbox_exec", "args": {"command": "rm -rf build"}}],
            "tenant-1",
            {
                "sandbox_enabled": True,
                "sandbox_manager": mgr,
                "execution_mode": "plan",
            },
        )
        payloads = [getattr(m, "payload", {}) for m in merged]
        assert any(
            isinstance(p, dict) and p.get("error") == "plan_mode_blocked"
            for p in payloads
        )
        assert created == []

        _context2, merged2 = await execute_tools_internal(
            [{"name": "sandbox_exec", "args": {"command": "ls -la"}}],
            "tenant-1",
            {
                "sandbox_enabled": True,
                "sandbox_manager": mgr,
                "execution_mode": "plan",
            },
        )
        payloads2 = [getattr(m, "payload", {}) for m in merged2]
        assert any(
            p.get("tool") == "sandbox_exec" and p.get("exit_code") == 0
            for p in payloads2
            if isinstance(p, dict)
        )

    @pytest.mark.asyncio
    async def test_auto_workspace_writes_dispatch(self):
        from backend.mcp_server.tool_dispatch import execute_tools_internal

        mgr, _created = _manager_with_fake()
        settings = {
            "sandbox_enabled": True,
            "sandbox_manager": mgr,
            "sandbox_autonomy_mode": "auto_workspace_writes",
        }
        # Workspace writes run without an approval round-trip.
        _c, merged = await execute_tools_internal(
            [{"name": "sandbox_write_file", "args": {"path": "a.txt", "content": "hi"}}],
            "tenant-1",
            settings,
        )
        payloads = [getattr(m, "payload", {}) for m in merged]
        assert any(
            p.get("tool") == "sandbox_write_file" for p in payloads
            if isinstance(p, dict)
        )
        assert not any(
            "approval_required" in p for p in payloads if isinstance(p, dict)
        )
        # git push still requires approval in this mode.
        _c2, merged2 = await execute_tools_internal(
            [{"name": "sandbox_exec", "args": {"command": "git push origin main"}}],
            "tenant-1",
            settings,
        )
        payloads2 = [getattr(m, "payload", {}) for m in merged2]
        assert any(
            "approval_required" in p for p in payloads2 if isinstance(p, dict)
        )

    @pytest.mark.asyncio
    async def test_auto_workspace_writes_dispatch_blocks_installs(self):
        # Regression (Phase 1, 1.2): mutating sandbox_exec commands
        # reach requires_approval with is_write=True from dispatch;
        # installs / network / destructive git must still be gated.
        from backend.mcp_server.tool_dispatch import execute_tools_internal

        mgr, created = _manager_with_fake()
        settings = {
            "sandbox_enabled": True,
            "sandbox_manager": mgr,
            "sandbox_autonomy_mode": "auto_workspace_writes",
        }
        for command in (
            "pip install requests",
            "curl https://evil.example/x",
            "git reset --hard",
            "rm ../outside.txt",
        ):
            _c, merged = await execute_tools_internal(
                [{"name": "sandbox_exec", "args": {"command": command}}],
                "tenant-1",
                settings,
            )
            payloads = [getattr(m, "payload", {}) for m in merged]
            assert any(
                "approval_required" in p for p in payloads
                if isinstance(p, dict)
            ), command
        assert created == []

    @pytest.mark.asyncio
    async def test_get_tools_absent_when_disabled(self):
        from backend.mcp_server.tool_dispatch import get_tools

        tools = await get_tools({}, tenant_id="tenant-1")
        names = [t["function"]["name"] for t in tools]
        assert not any(n.startswith("sandbox_") for n in names)

    @pytest.mark.asyncio
    async def test_exec_read_only_auto_runs_and_streams(self):
        from backend.mcp_server.tool_dispatch import execute_tools_internal

        mgr, _created = _manager_with_fake()
        context, merged = await execute_tools_internal(
            [{"name": "sandbox_exec", "args": {"command": "ls -la"}}],
            "tenant-1",
            {"sandbox_enabled": True, "sandbox_manager": mgr},
        )
        payloads = [getattr(m, "payload", {}) for m in merged]
        sandbox_payloads = [p for p in payloads if isinstance(p, dict) and p.get("tool") == "sandbox_exec"]
        assert sandbox_payloads, payloads
        assert sandbox_payloads[0]["exit_code"] == 0
        assert any(e["type"] == "stdout" for e in sandbox_payloads[0]["sandbox_events"])
        assert "ran:ls -la" in context

    @pytest.mark.asyncio
    async def test_exec_mutating_requires_approval_then_confirmed_runs(self):
        from backend.mcp_server.tool_dispatch import execute_tools_internal

        mgr, created = _manager_with_fake()
        _context, merged = await execute_tools_internal(
            [{"name": "sandbox_exec", "args": {"command": "rm -rf build"}}],
            "tenant-1",
            {"sandbox_enabled": True, "sandbox_manager": mgr},
        )
        payloads = [getattr(m, "payload", {}) for m in merged]
        approval = [p for p in payloads if isinstance(p, dict) and "approval_required" in p]
        assert approval, payloads
        assert approval[0]["approval_required"]["tool_name"] == "sandbox_exec"
        assert approval[0]["tool_confirmation_required"]["tool_name"] == "sandbox_exec"
        assert created == []  # nothing executed / no session started

        _context2, merged2 = await execute_tools_internal(
            [{"name": "sandbox_exec", "args": {"command": "rm -rf build"}}],
            "tenant-1",
            {
                "sandbox_enabled": True, "sandbox_manager": mgr,
                "confirmed_tool_names": ["sandbox_exec"],
            },
        )
        payloads2 = [getattr(m, "payload", {}) for m in merged2]
        assert any(p.get("tool") == "sandbox_exec" and p.get("exit_code") == 0 for p in payloads2 if isinstance(p, dict))

    @pytest.mark.asyncio
    async def test_git_push_requires_approval_even_autonomous(self):
        from backend.mcp_server.tool_dispatch import execute_tools_internal

        mgr, _created = _manager_with_fake()
        mgr.set_tenant_config("tenant-1", {"provider": "modal", "autonomy_mode": "autonomous"})
        _context, merged = await execute_tools_internal(
            [{"name": "sandbox_exec", "args": {"command": "git push origin main"}}],
            "tenant-1",
            {"sandbox_enabled": True, "sandbox_manager": mgr},
        )
        payloads = [getattr(m, "payload", {}) for m in merged]
        assert any("approval_required" in p for p in payloads if isinstance(p, dict))

    @pytest.mark.asyncio
    async def test_write_file_requires_approval_in_auto_mode(self):
        from backend.mcp_server.tool_dispatch import execute_tools_internal

        mgr, _created = _manager_with_fake()
        _context, merged = await execute_tools_internal(
            [{"name": "sandbox_write_file", "args": {"path": "a.txt", "content": "hi"}}],
            "tenant-1",
            {"sandbox_enabled": True, "sandbox_manager": mgr},
        )
        payloads = [getattr(m, "payload", {}) for m in merged]
        assert any(
            p.get("approval_required", {}).get("tool_name") == "sandbox_write_file"
            for p in payloads if isinstance(p, dict)
        )


class TestSandboxPolicyHardening:
    """Phase 1 (1.2): plan-mode and auto_workspace_writes bypasses."""

    def test_command_substitution_blocked_in_plan_mode(self):
        assert plan_mode_block(
            "plan", tool_name="sandbox_exec",
            command='git status "$(touch pwned)"',
        ) is not None
        assert plan_mode_block(
            "plan", tool_name="sandbox_exec", command="git status `id`"
        ) is not None
        assert plan_mode_block(
            "plan", tool_name="sandbox_exec", command="ls <(cat /etc/passwd)"
        ) is not None
        assert plan_mode_block(
            "plan", tool_name="sandbox_exec", command="ls\nrm -rf /"
        ) is not None

    def test_git_branch_argument_aware(self):
        assert classify_command("git branch -D feature") == "mutating"
        assert classify_command("git branch new-branch") == "mutating"
        assert classify_command("git branch -m old new") == "mutating"
        assert classify_command("git branch --list") == "read_only"
        assert classify_command("git branch --show-current") == "read_only"
        assert classify_command("git branch") == "read_only"
        assert plan_mode_block(
            "plan", tool_name="sandbox_exec", command="git branch -D feature"
        ) is not None
        assert plan_mode_block(
            "plan", tool_name="sandbox_exec", command="git branch --list"
        ) is None

    def test_auto_workspace_writes_path_confinement(self):
        mode = "auto_workspace_writes"
        assert requires_approval(mode, "rm ../outside.txt") is True
        assert requires_approval(mode, "rm -rf /etc") is True
        assert requires_approval(mode, "cp a.py /etc/cron.d/x") is True
        assert requires_approval(mode, "echo hi > /tmp/x") is True
        assert requires_approval(mode, "echo hi > ../x") is True
        assert requires_approval(mode, "echo hi > out.txt") is False
        assert requires_approval(mode, "rm src/old.py") is False
        # A known workspace root confines absolute paths against it.
        assert requires_approval(
            mode, "rm /tmp/ws/old.py", workspace_root="/tmp/ws"
        ) is False
        assert requires_approval(
            mode, "rm /tmp/other/old.py", workspace_root="/tmp/ws"
        ) is True

    def test_auto_workspace_writes_interpreters_gated(self):
        mode = "auto_workspace_writes"
        assert requires_approval(mode, "python -m pip install foo") is True
        assert requires_approval(mode, 'python -c "import os"') is True
        assert requires_approval(mode, "python script.py") is True
        assert requires_approval(mode, "node server.js") is True
        assert requires_approval(mode, "make build") is True
        assert requires_approval(mode, "python -m pytest -q") is False
        assert requires_approval(mode, "python -m ruff check .") is False

    def test_auto_workspace_writes_dispatch_style_is_write(self):
        # Regression: dispatch passes is_write=True for mutating
        # sandbox_exec commands; that must not short-circuit the
        # command analysis in auto_workspace_writes mode.
        mode = "auto_workspace_writes"
        assert requires_approval(mode, "pip install requests", is_write=True) is True
        assert requires_approval(mode, "curl https://evil.example", is_write=True) is True
        assert requires_approval(mode, "git reset --hard", is_write=True) is True

    def test_security_bypass_vectors_blocked(self):
        # Single-& command separator must not be treated as read-only.
        assert classify_command("ls & rm -rf /") == "mutating"
        assert classify_command('echo "a & b"') == "read_only"
        assert plan_mode_block("plan", tool_name="sandbox_exec", command="ls & rm -rf /") is not None
        assert requires_approval("auto_workspace_writes", "ls & rm -rf /") is True

        # Quoted redirection targets must still be confined to workspace.
        assert requires_approval("auto_workspace_writes", 'echo hi > "../outside.txt"') is True
        assert requires_approval("auto_workspace_writes", 'echo hi > "/tmp/outside.txt"') is True
        assert requires_approval("auto_workspace_writes", 'echo hi > "local.txt"') is False

        # Git global flags must not bypass is_git_push or read-only checks.
        assert requires_approval("autonomous", "git -C . push origin main") is True
        assert requires_approval("autonomous", "git --git-dir=.git push") is True
        assert classify_command("git config core.hooksPath /tmp") == "mutating"
        assert classify_command("git remote add origin https://evil.example") == "mutating"
        assert classify_command("git diff --output=/tmp/evil") == "mutating"
        assert classify_command("git -C . status") == "read_only"

        # Mutating flags on find / ln / cp must require approval.
        assert classify_command("find . -delete") == "mutating"
        assert classify_command("find . -exec rm {} +") == "mutating"
        assert classify_command("find . -name '*.py'") == "read_only"
        assert requires_approval("auto_workspace_writes", "ln -s /etc/passwd leak") is True
        assert requires_approval("auto_workspace_writes", "cp a --target-directory=/etc") is True

        # Read-only linters (ruff check / mypy) vs mutating flags.
        assert classify_command("ruff check --output-format sarif a.py") == "read_only"
        assert classify_command("ruff check --fix a.py") == "mutating"
        assert classify_command("ruff format a.py") == "mutating"
        assert classify_command("mypy --output json a.py") == "read_only"
        assert classify_command("mypy --install-types a.py") == "mutating"
