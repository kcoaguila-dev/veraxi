"""Tests for the curated GitHub tools and repo sync.

GitHub HTTP calls are patched at the module seams
(``github_tools._github_request``, ``github_sync._api`` /
``fetch_repo_tree`` / ``fetch_blob_text``) — no network is used.
"""

import base64

import pytest

from backend.mcp_server.tools import github_tools
from backend.services import github_sync


class _FakeResponse:
    def __init__(self, json_data=None, text=""):
        self._json = json_data if json_data is not None else {}
        self.text = text

    def json(self):
        return self._json


@pytest.fixture()
def _token(monkeypatch):
    async def fake_resolve(tenant_id, supabase=None):
        return "test-token"

    monkeypatch.setattr(github_tools, "_resolve_token", fake_resolve)


class TestConfirmationMarkers:
    def test_mutating_tools_gated(self):
        assert github_tools.requires_confirmation("github_create_issue")
        assert github_tools.requires_confirmation("github_comment_pr")

    def test_read_tools_not_gated(self):
        for name in (
            "github_list_repos",
            "github_search_code",
            "github_get_file",
            "github_list_issues_or_prs",
            "github_get_pr_diff",
        ):
            assert not github_tools.requires_confirmation(name)

    def test_schemas_cover_all_defs(self):
        names = {s["function"]["name"] for s in github_tools.tool_schemas()}
        assert names == {d["name"] for d in github_tools.TOOL_DEFS}


@pytest.mark.asyncio
class TestReadTools:
    async def test_list_repos(self, monkeypatch, _token):
        async def fake_request(token, method, path, **kwargs):
            assert method == "GET"
            assert path == "/user/repos"
            return _FakeResponse(
                [{"full_name": "kcoaguila-dev/veraxi", "private": True, "default_branch": "main"}]
            )

        monkeypatch.setattr(github_tools, "_github_request", fake_request)
        out = await github_tools.execute_github_tool("github_list_repos", {}, "t1")
        assert "kcoaguila-dev/veraxi" in out
        assert "private" in out

    async def test_search_code(self, monkeypatch, _token):
        async def fake_request(token, method, path, **kwargs):
            assert path == "/search/code"
            assert kwargs["params"]["q"] == "chunk repo:owner/repo"
            return _FakeResponse(
                {"items": [{"path": "a.py", "repository": {"full_name": "owner/repo"}}]}
            )

        monkeypatch.setattr(github_tools, "_github_request", fake_request)
        out = await github_tools.execute_github_tool(
            "github_search_code", {"query": "chunk", "repo": "owner/repo"}, "t1"
        )
        assert "a.py" in out

    async def test_get_file_decodes_base64(self, monkeypatch, _token):
        async def fake_request(token, method, path, **kwargs):
            return _FakeResponse(
                {
                    "content": base64.b64encode(b"hello world").decode(),
                    "encoding": "base64",
                }
            )

        monkeypatch.setattr(github_tools, "_github_request", fake_request)
        out = await github_tools.execute_github_tool(
            "github_get_file", {"repo": "o/r", "path": "README.md"}, "t1"
        )
        assert out == "hello world"

    async def test_list_prs(self, monkeypatch, _token):
        async def fake_request(token, method, path, **kwargs):
            assert path.endswith("/pulls")
            return _FakeResponse([{"number": 7, "title": "Fix", "state": "open"}])

        monkeypatch.setattr(github_tools, "_github_request", fake_request)
        out = await github_tools.execute_github_tool(
            "github_list_issues_or_prs", {"repo": "o/r", "type": "pr"}, "t1"
        )
        assert "#7" in out and "Fix" in out

    async def test_get_pr_diff(self, monkeypatch, _token):
        async def fake_request(token, method, path, **kwargs):
            return _FakeResponse(text="diff --git a/x b/x")

        monkeypatch.setattr(github_tools, "_github_request", fake_request)
        out = await github_tools.execute_github_tool(
            "github_get_pr_diff", {"repo": "o/r", "pr_number": 3}, "t1"
        )
        assert out.startswith("diff --git")


@pytest.mark.asyncio
class TestWriteTools:
    async def test_create_issue(self, monkeypatch, _token):
        async def fake_request(token, method, path, **kwargs):
            assert method == "POST"
            assert kwargs["json"]["title"] == "Bug"
            return _FakeResponse({"number": 42, "html_url": "https://github.com/o/r/issues/42"})

        monkeypatch.setattr(github_tools, "_github_request", fake_request)
        out = await github_tools.execute_github_tool(
            "github_create_issue", {"repo": "o/r", "title": "Bug", "body": "b"}, "t1"
        )
        assert "#42" in out


class TestSyncFiltering:
    def test_skips_binary_lock_and_vendor(self):
        assert github_sync.should_ingest_file("src/main.py", 100)
        assert github_sync.should_ingest_file("README.md", 100)
        assert not github_sync.should_ingest_file("assets/logo.png", 100)
        assert not github_sync.should_ingest_file("package-lock.json", 100)
        assert not github_sync.should_ingest_file("node_modules/x/index.js", 100)
        assert not github_sync.should_ingest_file("vendor/lib/util.py", 100)
        assert not github_sync.should_ingest_file("big.py", 10_000_000)


@pytest.mark.asyncio
class TestIncrementalSync:
    async def test_only_changed_files_ingested(self, monkeypatch):
        ingested_texts = []

        async def fake_tree(token, repo, branch=None):
            return "main", [
                {"path": "a.py", "sha": "sha-a", "size": 10},
                {"path": "b.py", "sha": "sha-b2", "size": 10},
            ]

        async def fake_blob(token, repo, sha):
            return f"content-{sha}"

        def fake_run(texts, tenant_id, schema):
            ingested_texts.extend(texts)
            return len(texts)

        monkeypatch.setattr(github_sync, "fetch_repo_tree", fake_tree)
        monkeypatch.setattr(github_sync, "fetch_blob_text", fake_blob)
        monkeypatch.setattr(github_sync, "_run_ingestion_for_texts", fake_run)

        updates = {}

        def fake_update(sb, tenant_id, integration_id, **kwargs):
            updates.update(kwargs)
            return {"id": integration_id, **kwargs}

        monkeypatch.setattr(github_sync.store, "update_integration", fake_update)

        row = {
            "id": "int-1",
            "config": {"synced_repos": {"o/r": {"files": {"a.py": "sha-a", "b.py": "sha-b1"}}}},
        }
        result = await github_sync.sync_github_repo(
            object(), "t1", row, "o/r", token="tok", schema={"entities": []}
        )
        assert result["status"] == "ok"
        assert result["changed_files"] == 1  # only b.py changed
        assert [src for src, _ in ingested_texts] == ["github://o/r/b.py"]
        assert updates["config"]["synced_repos"]["o/r"]["files"]["b.py"] == "sha-b2"

    async def test_missing_schema_fails_cleanly(self):
        row = {"id": "int-1", "config": {}}
        result = await github_sync.sync_github_repo(
            object(), "t1", row, "o/r", token="tok", schema=None
        )
        assert result["status"] == "error"


class TestWorkerTask:
    def test_sync_task_registered(self):
        from backend.worker import WorkerSettings, sync_github_repo_task

        assert sync_github_repo_task in WorkerSettings.functions


class TestDispatchGate:
    @pytest.mark.asyncio
    async def test_gated_tool_returns_confirmation_not_execution(self, monkeypatch):
        from backend.mcp_server import tool_dispatch

        async def fake_execute(*a, **k):  # pragma: no cover - must not run
            raise AssertionError("gated tool must not execute unconfirmed")

        monkeypatch.setattr(github_tools, "execute_github_tool", fake_execute)
        context, merged = await tool_dispatch.execute_tools_internal(
            [{"name": "github_create_issue", "args": {"repo": "o/r", "title": "x"}}],
            "tenant-1",
            {},
        )
        assert "tool_confirmation_required" in context
        assert merged and merged[0].id == "tool_confirmation"

    @pytest.mark.asyncio
    async def test_confirmed_tool_executes(self, monkeypatch):
        from backend.mcp_server import tool_dispatch

        async def fake_execute(name, args, tenant_id, supabase=None):
            return "Created issue #1"

        monkeypatch.setattr(github_tools, "execute_github_tool", fake_execute)
        context, _merged = await tool_dispatch.execute_tools_internal(
            [{"name": "github_create_issue", "args": {"repo": "o/r", "title": "x"}}],
            "tenant-1",
            {"confirmed_tool_names": ["github_create_issue"]},
        )
        assert "Created issue #1" in context
