"""Tests for shared tenant-scoped repo file/tree access and workspace context."""

from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from backend.services import repo_context, repo_files


class _FakeNeo4j:
    def __init__(self, meta_by_repo: dict[str, dict] | None = None):
        self.meta_by_repo = meta_by_repo or {}

    def execute_read(self, query: str, params: dict):
        del query
        repo_key = params.get("repo_key")
        if repo_key is None:
            return []
        meta = self.meta_by_repo.get(repo_key)
        return [meta] if meta else []


class _FakeRedis:
    def __init__(self):
        self.data: dict[str, str] = {}

    async def get(self, key: str):
        return self.data.get(key)

    async def setex(self, key: str, ttl: int, value: str):
        del ttl
        self.data[key] = value


@pytest.mark.asyncio
async def test_read_repo_file_local_checkout_and_slicing(tmp_path, monkeypatch):
    repo_dir = tmp_path / "veraxi"
    repo_dir.mkdir()
    (repo_dir / "README.md").write_text("line1\nline2\nline3\nline4\n", encoding="utf-8")
    monkeypatch.setattr(repo_files, "allowed_code_roots", lambda: [str(tmp_path)])

    neo4j = _FakeNeo4j(
        {
            "kcoaguila-dev/veraxi": {
                "repo_key": "kcoaguila-dev/veraxi",
                "repo_root": str(repo_dir),
                "source_commit": "abc123456789",
                "kind": "local",
            }
        }
    )
    res = await repo_files.read_repo_file(
        "t1",
        "kcoaguila-dev/veraxi",
        "README.md",
        start_line=2,
        end_line=3,
        neo4j_client=neo4j,
        supabase=False,
    )
    assert res["path"] == "README.md"
    assert res["content"] == "line2\nline3"
    assert res["start_line"] == 2
    assert res["end_line"] == 3
    assert res["total_lines"] == 4
    assert res["url"] == "file://README.md#L2-L3"


@pytest.mark.asyncio
async def test_read_repo_file_rejects_traversal_and_unowned_repo(tmp_path, monkeypatch):
    monkeypatch.setattr(repo_files, "allowed_code_roots", lambda: [str(tmp_path)])
    with pytest.raises(repo_files.RepoFileError) as exc_info:
        await repo_files.read_repo_file(
            "t1", "kcoaguila-dev/veraxi", "../etc/passwd", neo4j_client=_FakeNeo4j(), supabase=False
        )
    assert exc_info.value.status_code == 403

    with pytest.raises(repo_files.RepoFileError) as exc_unowned:
        await repo_files.read_repo_file(
            "t1", "other/secret-repo", "README.md", neo4j_client=_FakeNeo4j(), supabase=False
        )
    assert exc_unowned.value.status_code == 404


@pytest.mark.asyncio
async def test_github_app_list_and_read_with_redis_cache(monkeypatch):
    from backend.services import github_app_client, github_app_store

    neo4j = _FakeNeo4j(
        {
            "kcoaguila-dev/veraxi": {
                "repo_key": "kcoaguila-dev/veraxi",
                "repo_root": "github://kcoaguila-dev/veraxi",
                "source_commit": "deadbeef1234",
                "kind": "github_app",
            }
        }
    )
    redis = _FakeRedis()
    fake_sb = MagicMock()

    monkeypatch.setattr(
        github_app_store,
        "get_repo",
        lambda sb, tid, key: {"installation_id": 42, "default_branch": "main"}
        if tid == "t1" and key == "kcoaguila-dev/veraxi"
        else None,
    )
    monkeypatch.setattr(
        github_app_client,
        "get_installation_token",
        AsyncMock(return_value="ghs_test_token"),
    )
    tree_mock = AsyncMock(
        return_value=[
            {"path": "README.md", "name": "README.md", "type": "file", "size": 120},
            {"path": "backend", "name": "backend", "type": "dir", "size": None},
            {"path": "backend/config.py", "name": "config.py", "type": "file", "size": 400},
        ]
    )
    monkeypatch.setattr(github_app_client, "fetch_repo_tree_at_ref", tree_mock)
    file_mock = AsyncMock(return_value="# Veraxi\nGraphRAG Workspace")
    monkeypatch.setattr(github_app_client, "fetch_file_at_ref", file_mock)

    listed = await repo_files.list_repo_entries(
        "t1", "kcoaguila-dev/veraxi", path="", neo4j_client=neo4j, supabase=fake_sb, redis_client=redis
    )
    assert [e["path"] for e in listed["entries"]] == ["backend", "README.md"]
    assert tree_mock.await_count == 1

    # Second listing hits Redis cache
    listed_sub = await repo_files.list_repo_entries(
        "t1",
        "kcoaguila-dev/veraxi",
        path="backend",
        neo4j_client=neo4j,
        supabase=fake_sb,
        redis_client=redis,
    )
    assert [e["path"] for e in listed_sub["entries"]] == ["backend/config.py"]
    assert tree_mock.await_count == 1

    # File read caches in Redis too
    f1 = await repo_files.read_repo_file(
        "t1", "kcoaguila-dev/veraxi", "README.md", neo4j_client=neo4j, supabase=fake_sb, redis_client=redis
    )
    f2 = await repo_files.read_repo_file(
        "t1", "kcoaguila-dev/veraxi", "README.md", neo4j_client=neo4j, supabase=fake_sb, redis_client=redis
    )
    assert f1["content"] == "# Veraxi\nGraphRAG Workspace"
    assert f2["source"] == "github_app"
    assert file_mock.await_count == 1
    assert json.loads(redis.data["ghapp:tree:t1:kcoaguila-dev/veraxi:deadbeef1234"])


@pytest.mark.asyncio
async def test_build_workspace_context_prompt_code_vs_chat(tmp_path, monkeypatch):
    repo_dir = tmp_path / "veraxi"
    repo_dir.mkdir()
    (repo_dir / "README.md").write_text("# Veraxi", encoding="utf-8")
    (repo_dir / "AGENTS.md").write_text("Follow AGENTS rules.", encoding="utf-8")
    monkeypatch.setattr(repo_files, "allowed_code_roots", lambda: [str(tmp_path)])

    neo4j = _FakeNeo4j(
        {
            "kcoaguila-dev/veraxi": {
                "repo_key": "kcoaguila-dev/veraxi",
                "repo_root": str(repo_dir),
                "source_commit": "abc123456789",
                "kind": "local",
            }
        }
    )

    # Chat Mode without repo -> None
    assert (
        await repo_context.build_workspace_context_prompt(
            "t1", {"workspace_mode": "chat"}, neo4j_client=neo4j, supabase=False
        )
        is None
    )

    # Code Mode with repo_key -> <workspace_context> with entries & AGENTS.md (not README)
    prompt = await repo_context.build_workspace_context_prompt(
        "t1",
        {
            "workspace_mode": "code",
            "repo_key": "kcoaguila-dev/veraxi",
            "branch": "main",
            "execution_mode": "act",
            "source_scope": {"repo_keys": ["kcoaguila-dev/veraxi"], "doc_ids": ["d1"]},
        },
        neo4j_client=neo4j,
        supabase=False,
    )
    assert prompt is not None
    assert "Active Repository: kcoaguila-dev/veraxi" in prompt
    assert "README.md" in prompt
    assert "Follow AGENTS rules." in prompt
    assert "# Veraxi" not in prompt
    assert "NEVER ask the user which repository" in prompt


def test_code_budget_for_model_prioritizes_paid_models():
    assert repo_files.code_budget_for_model("claude-sonnet-4-5") == (6_000, 24_000)
    assert repo_files.code_budget_for_model("gemini/gemini-2.5-pro") == (6_000, 24_000)
    assert repo_files.code_budget_for_model("openai/gpt-4o") == (6_000, 24_000)
    assert repo_files.code_budget_for_model(None) == (6_000, 24_000)
    # Groq / tight-TPM models get compact budgets
    assert repo_files.code_budget_for_model("openai/gpt-oss-20b") == (1_200, 8_000)
    assert repo_files.code_budget_for_model("groq/llama-3.3-70b-versatile") == (1_200, 8_000)
