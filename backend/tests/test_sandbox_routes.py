"""Route tests for /api/v1/sandboxes/* with a mocked Supabase client."""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from backend.routes import sandboxes as sandbox_routes
from backend.sandbox.manager import SandboxManager
from backend.sandbox.ws_runner_provider import GLOBAL_REGISTRY
from backend.security.token_vault import decrypt_secrets
from backend.services import sandbox_store as store
from test_sandbox_manager import FakeProvider, FakeSupabase


@pytest.fixture()
def harness(monkeypatch):
    monkeypatch.setenv("INTEGRATION_ENCRYPTION_KEY", "route-sandbox-key")
    from backend.config import get_config

    get_config.cache_clear()
    fake = FakeSupabase()
    mgr = SandboxManager(provider_factory=lambda s, sec: FakeProvider(s, sec))
    mgr.set_tenant_config(
        "tenant-1",
        {"provider": "modal", "autonomy_mode": "auto_read_test"},
        secrets={"runner_token": "runner-tok-1"},
    )
    app = FastAPI()
    sandbox_routes.register_sandbox_routes(
        app, lambda: "tenant-1", lambda: fake, None, manager=mgr
    )
    yield TestClient(app, raise_server_exceptions=False), fake, mgr
    GLOBAL_REGISTRY.unregister("tenant-1")
    get_config.cache_clear()


class TestConfigRoutes:
    def test_get_default_config_masked(self, harness):
        tc, _fake, _mgr = harness
        resp = tc.get("/api/v1/sandboxes/config")
        assert resp.status_code == 200
        body = resp.json()
        assert body["has_secrets"] is False
        assert "encrypted_secrets" not in body
        assert body["provider"] in ("disabled", "modal", "e2b", "remote_mcp", "local_runner")

    def test_put_encrypts_and_get_masks(self, harness):
        tc, fake, _mgr = harness
        resp = tc.put("/api/v1/sandboxes/config", json={
            "provider": "modal", "cpu_cores": 8,
            "secrets": {"modal_token_id": "mid", "modal_token_secret": "msecret"},
        })
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["has_secrets"] is True
        assert body["cpu_cores"] == 8
        assert "msecret" not in resp.text
        row = fake.table(store.CONFIG_TABLE).rows[0]
        assert "msecret" not in row["encrypted_secrets"]
        assert decrypt_secrets(row["encrypted_secrets"])["modal_token_secret"] == "msecret"
        resp2 = tc.get("/api/v1/sandboxes/config")
        assert resp2.json()["has_secrets"] is True
        assert "msecret" not in resp2.text

    def test_put_invalid_provider_400(self, harness):
        tc, _fake, _mgr = harness
        resp = tc.put("/api/v1/sandboxes/config", json={"provider": "nope"})
        assert resp.status_code == 400


class TestTestEndpoint:
    def test_test_boots_runs_and_tears_down(self, harness):
        tc, _fake, mgr = harness
        resp = tc.post("/api/v1/sandboxes/test", json={})
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["status"] == "running"
        assert isinstance(body["latency_ms"], int)
        assert "uname -a" in body["output"]
        assert mgr.list_session_infos("tenant-1") == []  # torn down


class TestSessionRoutes:
    @pytest.mark.asyncio
    async def _start(self, mgr):
        return await mgr.start_session("tenant-1", chat_id="chat-9")

    def test_list_pause_approve_delete(self, harness):
        tc, _fake, mgr = harness
        import asyncio

        info = asyncio.run(mgr.start_session("tenant-1", chat_id="chat-9"))
        resp = tc.get("/api/v1/sandboxes/sessions")
        assert resp.status_code == 200
        ids = [s["id"] for s in resp.json()["sessions"]]
        assert info.session_id in ids

        mgr.record_approval_request(info.session_id, {"tool_name": "sandbox_exec"})
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{info.session_id}/approve",
            json={"approve": True, "tool_name": "sandbox_exec"},
        )
        assert resp.status_code == 200
        assert resp.json()["status"] == "approved"
        assert resp.json()["resolved"] == 1

        resp = tc.post(f"/api/v1/sandboxes/sessions/{info.session_id}/pause")
        assert resp.status_code == 200
        assert resp.json()["status"] == "paused"

        resp = tc.delete(f"/api/v1/sandboxes/sessions/{info.session_id}")
        assert resp.status_code == 200
        assert resp.json()["status"] == "stopped"

    def test_pause_unknown_session_404(self, harness):
        tc, _fake, _mgr = harness
        resp = tc.post("/api/v1/sandboxes/sessions/does-not-exist/pause")
        assert resp.status_code == 404

    def test_approve_unknown_session_404(self, harness):
        tc, _fake, _mgr = harness
        resp = tc.post(
            "/api/v1/sandboxes/sessions/does-not-exist/approve", json={"approve": True}
        )
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Code Mode Phase 2: diff / accept / revert / commit
# ---------------------------------------------------------------------------

from backend.sandbox.base import ExecEvent
from backend.sandbox.git_diff import language_for_path, parse_numstat

NUMSTAT = "5\t2\tsrc/main.py\n4\t0\tdocs/guide.md\n"
UNIFIED_DIFF = """diff --git a/src/main.py b/src/main.py
--- a/src/main.py
+++ b/src/main.py
@@ -1,3 +1,6 @@
 line1
-old
+new
+extra
diff --git a/docs/guide.md b/docs/guide.md
new file mode 100644
--- /dev/null
+++ b/docs/guide.md
@@ -0,0 +1,4 @@
+# Guide
+text
"""
UNTRACKED_PREVIEW = """diff --git a/notes.txt b/notes.txt
new file mode 100644
--- /dev/null
+++ b/notes.txt
@@ -0,0 +1,2 @@
+hello
+world
"""


class GitFakeProvider(FakeProvider):
    """FakeProvider whose exec answers git commands with canned output."""

    def __init__(self, settings, secrets=None):
        super().__init__(settings, secrets)
        self.not_git = False
        self.commit_exit = 0
        self.tracked = {"src/main.py", "docs/guide.md"}
        self.removed: list[str] = []

    async def exec_command(self, session_id, cmd, cwd=None, timeout_sec=120):
        self.commands.append(cmd)
        stdout, exit_code = self._dispatch(cmd)
        if stdout:
            yield ExecEvent(kind="stdout", data=stdout)
        yield ExecEvent(kind="exit", data="", exit_code=exit_code)

    def _dispatch(self, cmd):
        normalized = cmd.replace("git -c core.quotepath=false ", "git ", 1)
        if normalized.startswith("git rev-parse"):
            if self.not_git:
                return "", 128
            return "/repo\n", 0
        if normalized.startswith("git diff --no-index"):
            return UNTRACKED_PREVIEW, 1
        if normalized.startswith("git diff HEAD --numstat"):
            return NUMSTAT, 0
        if normalized.startswith("git diff HEAD"):
            return UNIFIED_DIFF, 0
        if normalized.startswith("git ls-files --others"):
            return "notes.txt\n", 0
        if normalized.startswith("git cat-file -e HEAD:"):
            path = normalized.split("HEAD:", 1)[-1].strip("'\"")
            return ("", 0) if path in self.tracked else ("", 1)
        if normalized.startswith("git ls-files --error-unmatch"):
            path = normalized.rsplit("-- ", 1)[-1].strip("'\"")
            return ("", 0) if path in self.tracked else ("", 1)
        if normalized.startswith("git commit"):
            return ("", self.commit_exit)
        if normalized.startswith("rm -f --"):
            self.removed.append(normalized.rsplit("-- ", 1)[-1].strip("'\""))
            return "", 0
        return "", 0


@pytest.fixture()
def git_harness(monkeypatch):
    monkeypatch.setenv("INTEGRATION_ENCRYPTION_KEY", "route-sandbox-key")
    from backend.config import get_config

    get_config.cache_clear()
    fake = FakeSupabase()
    created = []

    def factory(settings, secrets):
        provider = GitFakeProvider(settings, secrets)
        created.append(provider)
        return provider

    mgr = SandboxManager(provider_factory=factory)
    mgr.set_tenant_config(
        "tenant-1",
        {"provider": "modal", "autonomy_mode": "auto_read_test"},
        secrets={"runner_token": "runner-tok-1"},
    )
    app = FastAPI()
    sandbox_routes.register_sandbox_routes(
        app, lambda: "tenant-1", lambda: fake, None, manager=mgr
    )
    yield TestClient(app, raise_server_exceptions=False), fake, mgr, created
    GLOBAL_REGISTRY.unregister("tenant-1")
    get_config.cache_clear()


def _git_session(git_harness):
    _tc, _fake, mgr, created = git_harness
    import asyncio

    info = asyncio.run(mgr.start_session("tenant-1", chat_id="chat-9"))
    return info.session_id, created[-1]


class TestGitDiffHelpers:
    def test_language_map_and_fallback(self):
        assert language_for_path("a/b.py") == "python"
        assert language_for_path("lib/main.dart") == "dart"
        assert language_for_path("web/app.ts") == "typescript"
        assert language_for_path("web/app.js") == "javascript"
        assert language_for_path("pyproject.toml") == "toml"
        assert language_for_path("x.yaml") == "yaml"
        assert language_for_path("x.json") == "json"
        assert language_for_path("README.md") == "markdown"
        assert language_for_path("Dockerfile") == "dockerfile"
        assert language_for_path("data.weirdext") == "weirdext"
        assert language_for_path("LICENSE") == "text"

    def test_parse_numstat_binary_and_rename(self):
        stats = parse_numstat("-\t-\timg.png\n1\t2\told.py => new.py\n")
        assert stats["img.png"] == (0, 0)
        assert stats["new.py"] == (1, 2)


class TestDiffEndpoint:
    def test_diff_shape_counts_hunks_and_untracked(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, _provider = _git_session(git_harness)
        resp = tc.get(
            f"/api/v1/sandboxes/sessions/{session_id}/diff",
            params={"turn_id": "turn-7"},
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert set(body) == {
            "session_id", "turn_id", "total_additions", "total_deletions", "files",
        }
        assert body["session_id"] == session_id
        assert body["turn_id"] == "turn-7"
        assert body["total_additions"] == 5 + 4 + 2
        assert body["total_deletions"] == 2
        by_path = {f["path"]: f for f in body["files"]}
        assert set(by_path) == {"src/main.py", "docs/guide.md", "notes.txt"}
        main = by_path["src/main.py"]
        assert main["language"] == "python"
        assert main["status"] == "modified"
        assert (main["additions"], main["deletions"]) == (5, 2)
        assert main["hunks"][0]["old_start"] == 1
        assert main["hunks"][0]["new_start"] == 1
        assert "+new" in main["hunks"][0]["lines"]
        guide = by_path["docs/guide.md"]
        assert guide["language"] == "markdown"
        assert guide["status"] == "added"
        notes = by_path["notes.txt"]
        assert notes["language"] == "text"
        assert notes["status"] == "untracked"
        assert notes["additions"] == 2
        assert notes["hunks"][0]["lines"][-1] == "+world"

    def test_diff_unknown_session_404(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        resp = tc.get("/api/v1/sandboxes/sessions/nope/diff")
        assert resp.status_code == 404

    def test_diff_not_a_git_repo_400(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        provider.not_git = True
        resp = tc.get(f"/api/v1/sandboxes/sessions/{session_id}/diff")
        assert resp.status_code == 400


class TestAcceptRevertCommit:
    def test_accept_stages_each_file_after_double_dash(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/accept",
            json={"paths": ["src/main.py", "docs/guide.md"]},
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["accepted"] == ["src/main.py", "docs/guide.md"]
        add_cmds = [c for c in provider.commands if c.startswith("git add")]
        assert add_cmds == ["git add -- src/main.py", "git add -- docs/guide.md"]

    def test_accept_absolute_path_inside_root_is_normalized(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/accept",
            json={"paths": ["/repo/src/main.py"]},
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["accepted"] == ["src/main.py"]
        assert "git add -- src/main.py" in provider.commands

    @pytest.mark.parametrize(
        "bad_path",
        [
            "../secret.txt",
            "src/../../secret.txt",
            "..",
            "/etc/passwd",
            "/repo/../etc/passwd",
            "/repo",
            "",
            "   ",
            "--cached",
            "-f",
            "--",
            "src/main.py\x00.png",
        ],
    )
    def test_accept_rejects_adversarial_paths(self, git_harness, bad_path):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/accept",
            json={"paths": [bad_path]},
        )
        assert resp.status_code == 400, (bad_path, resp.text)
        assert not [c for c in provider.commands if c.startswith("git add")]

    def test_accept_empty_paths_400(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, _provider = _git_session(git_harness)
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/accept",
            json={"paths": []},
        )
        assert resp.status_code == 400

    def test_revert_tracked_uses_checkout_untracked_removed(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/revert",
            json={"paths": ["src/main.py", "notes.txt"]},
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["reverted"] == ["src/main.py", "notes.txt"]
        assert "git checkout HEAD -- src/main.py" in provider.commands
        assert provider.removed == ["notes.txt"]
        assert not [c for c in provider.commands if c.startswith("git checkout -- notes")]

    @pytest.mark.parametrize("bad_path", ["../x.py", "/etc/passwd", "--force", ""])
    def test_revert_rejects_adversarial_paths(self, git_harness, bad_path):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/revert",
            json={"paths": [bad_path]},
        )
        assert resp.status_code == 400
        assert provider.removed == []
        assert not [c for c in provider.commands if c.startswith("git checkout")]

    def test_accept_unknown_session_404(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        resp = tc.post(
            "/api/v1/sandboxes/sessions/nope/files/accept",
            json={"paths": ["a.py"]},
        )
        assert resp.status_code == 404

    def test_commit_staged_never_pushes(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/commit",
            json={"message": "feat: add guide"},
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["committed"] is True
        commit_cmds = [c for c in provider.commands if c.startswith("git commit")]
        assert commit_cmds == ["git commit -m 'feat: add guide'"]
        assert all("push" not in c for c in provider.commands)

    def test_commit_empty_message_400_and_no_commit_run(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        for message in ("", "   "):
            resp = tc.post(
                f"/api/v1/sandboxes/sessions/{session_id}/commit",
                json={"message": message},
            )
            assert resp.status_code == 400
        assert not [c for c in provider.commands if c.startswith("git commit")]

    def test_commit_failure_400(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        provider.commit_exit = 1
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/commit",
            json={"message": "nothing staged"},
        )
        assert resp.status_code == 400


class TestRunnerWebSocket:
    def test_ws_accepts_valid_runner_token(self, harness):
        tc, _fake, _mgr = harness
        with tc.websocket_connect(
            "/api/v1/sandboxes/runner/ws?tenant_id=tenant-1&token=runner-tok-1"
        ):
            assert GLOBAL_REGISTRY.is_connected("tenant-1") is True
        assert GLOBAL_REGISTRY.is_connected("tenant-1") is False

    def test_ws_rejects_bad_token(self, harness):
        tc, _fake, _mgr = harness
        with pytest.raises(WebSocketDisconnect), tc.websocket_connect(
            "/api/v1/sandboxes/runner/ws?tenant_id=tenant-1&token=wrong"
        ):
            pass


class TestPhase2Remediation:
    """Phase 2 fixes: tenant fail-closed, .git paths, HEAD revert, preview cap."""

    def test_session_with_missing_tenant_is_not_found(self, git_harness):
        tc, _fake, mgr, _created = git_harness
        session_id, _provider = _git_session(git_harness)
        _provider2, info = mgr._sessions[session_id]
        for bad_tenant in (None, ""):
            info.tenant_id = bad_tenant
            resp = tc.get(f"/api/v1/sandboxes/sessions/{session_id}/diff")
            assert resp.status_code == 404, (bad_tenant, resp.text)
        info.tenant_id = "tenant-1"
        resp = tc.get(f"/api/v1/sandboxes/sessions/{session_id}/diff")
        assert resp.status_code == 200, resp.text

    @pytest.mark.parametrize("bad_path", [".git/HEAD", ".git/hooks/pre-commit", "src/.git/config"])
    def test_accept_rejects_git_internals(self, git_harness, bad_path):
        tc, _fake, _mgr, _created = git_harness
        session_id, _provider = _git_session(git_harness)
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/accept",
            json={"paths": [bad_path]},
        )
        assert resp.status_code == 400, resp.text

    def test_revert_after_accept_restores_head_and_removes_new_file(self, git_harness):
        tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        # Accept (stage) both a tracked file and a brand-new file,
        # then revert: tracked must restore from HEAD (not the index)
        # and the new file must be unstaged + removed.
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/accept",
            json={"paths": ["src/main.py", "notes.txt"]},
        )
        assert resp.status_code == 200, resp.text
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/revert",
            json={"paths": ["src/main.py", "notes.txt"]},
        )
        assert resp.status_code == 200, resp.text
        assert "git checkout HEAD -- src/main.py" in provider.commands
        assert not any(
            c == "git checkout -- src/main.py" for c in provider.commands
        )
        assert any(
            c.startswith("git rm -f --cached") and "notes.txt" in c
            for c in provider.commands
        )
        assert provider.removed == ["notes.txt"]

    def test_untracked_preview_capped_at_200_lines(self, git_harness, monkeypatch):
        import asyncio

        from backend.sandbox import git_diff as gd

        _tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        big_preview = "\n".join(
            ["diff --git a/big.txt b/big.txt", "--- /dev/null", "+++ b/big.txt",
             "@@ -0,0 +1,500 @@"]
            + [f"+line {i}" for i in range(500)]
        )

        async def fake_gather(_provider, _sid, cmd):
            norm = cmd.replace("git -c core.quotepath=false ", "git ", 1)
            if norm.startswith("git diff --no-index"):
                return big_preview, "", 1
            if norm.startswith("git ls-files --others"):
                return "big.txt\n", "", 0
            if norm.startswith("git diff HEAD --numstat"):
                return "", "", 0
            if norm.startswith("git diff HEAD"):
                return "", "", 0
            return "/repo\n", "", 0

        monkeypatch.setattr(gd, "_gather", fake_gather)
        summary = asyncio.run(gd.collect_session_diff(provider, session_id))
        files = {f["path"]: f for f in summary["files"]}
        assert "big.txt" in files
        total_lines = sum(len(h["lines"]) for h in files["big.txt"]["hunks"])
        assert total_lines <= gd._UNTRACKED_PREVIEW_LINES + 5
        assert files["big.txt"]["additions"] <= gd._UNTRACKED_PREVIEW_LINES

    def test_untracked_files_capped_at_max(self, git_harness, monkeypatch):
        import asyncio

        from backend.sandbox import git_diff as gd

        _tc, _fake, _mgr, _created = git_harness
        session_id, provider = _git_session(git_harness)
        untracked_listing = "\n".join(f"file_{i}.txt" for i in range(65)) + "\n"

        async def fake_gather(_provider, _sid, cmd):
            norm = cmd.replace("git -c core.quotepath=false ", "git ", 1)
            if norm.startswith("git ls-files --others"):
                return untracked_listing, "", 0
            if norm.startswith("git diff --no-index"):
                return "", "", 1
            return ("/repo\n", "", 0) if norm.startswith("git rev-parse") else ("", "", 0)

        monkeypatch.setattr(gd, "_gather", fake_gather)
        summary = asyncio.run(gd.collect_session_diff(provider, session_id))
        assert len(summary["files"]) == gd._MAX_UNTRACKED_FILES
        assert summary.get("untracked_truncated") is True

    def test_accept_unexpected_error_returns_502(self, git_harness, monkeypatch):
        from backend.routes import sandboxes as sb_routes

        tc, _fake, _mgr, _created = git_harness
        session_id, _provider = _git_session(git_harness)

        async def boom(*_a, **_kw):
            raise RuntimeError("runner disconnected")

        monkeypatch.setattr(sb_routes, "git_add_paths", boom)
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{session_id}/files/accept",
            json={"paths": ["src/main.py"]},
        )
        assert resp.status_code == 502
