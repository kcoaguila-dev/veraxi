"""Tests for zero-retention ephemeral GitHub App indexing and purge."""

from __future__ import annotations

import io
import tarfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest

from backend.services import github_app_ingest as gh_ingest
from backend.tests.test_code_freshness import ModelNeo4jClient
from backend.tests.test_oauth_service import _FakeTable


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables = {
            "github_app_installations": _FakeTable(),
            "github_app_repos": _FakeTable(),
        }

    def table(self, name: str):
        return self.tables[name]


def _make_tarball(files: dict[str, str]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for rel, text in files.items():
            raw = text.encode("utf-8")
            info = tarfile.TarInfo(name=f"org-repo-abc123/{rel}")
            info.size = len(raw)
            tf.addfile(info, io.BytesIO(raw))
    return buf.getvalue()


@pytest.mark.asyncio
async def test_index_github_app_repo_writes_graph_and_wipes_temp_dir():
    sb = _FakeSupabase()
    neo4j = ModelNeo4jClient()
    cfg = SimpleNamespace(github_app_max_repo_mb=10)
    archive = _make_tarball(
        {
            "app.py": "def greet(name):\n    return f'hi {name}'\n",
            "package.json": '{"dependencies": {"lodash": "^4.17.21"}}\n',
        }
    )
    created_dirs: list[Path] = []

    async def _fake_download(token, repo_full_name, ref, dest_dir: Path, max_bytes=0):
        created_dirs.append(dest_dir)
        from backend.services.github_app_client import _safe_extract_tarball

        _safe_extract_tarball(archive, dest_dir)

    with (
        patch.object(
            gh_ingest.gh_client,
            "get_installation_token",
            AsyncMock(return_value="ghs_tok"),
        ),
        patch.object(
            gh_ingest.gh_client,
            "get_branch_head_sha",
            AsyncMock(return_value="sha_111"),
        ),
        patch.object(
            gh_ingest.gh_client, "download_repo_tarball", side_effect=_fake_download
        ),
    ):
        result = await gh_ingest.index_github_app_repo(
            cfg,
            sb,
            None,
            tenant_id="tenant-1",
            installation_id=77,
            repo_full_name="acme/demo",
            branch="main",
            neo4j_client=neo4j,
        )

    assert result["status"] == "ok"
    assert result["repo_key"] == "acme/demo"
    assert result["source_commit"] == "sha_111"
    assert result["nodes_written"] > 0
    # Zero retention: temp directory must be deleted immediately.
    assert created_dirs and not created_dirs[0].exists()
    # Supabase repo row is marked indexed.
    rows = sb.tables["github_app_repos"].rows
    assert len(rows) == 1
    assert rows[0]["index_status"] == "indexed"
    assert rows[0]["last_indexed_sha"] == "sha_111"
    assert len(rows[0]["dependencies_snapshot"]) == 1
    assert rows[0]["dependencies_snapshot"][0]["name"] == "lodash"


@pytest.mark.asyncio
async def test_incremental_update_preserves_repo_metadata_and_updates_sha():
    sb = _FakeSupabase()
    neo4j = ModelNeo4jClient()
    cfg = SimpleNamespace(github_app_max_repo_mb=10)
    archive = _make_tarball({"app.py": "def v1():\n    return 1\n"})

    async def _fake_download(token, repo_full_name, ref, dest_dir: Path, max_bytes=0):
        from backend.services.github_app_client import _safe_extract_tarball

        _safe_extract_tarball(archive, dest_dir)

    with (
        patch.object(
            gh_ingest.gh_client,
            "get_installation_token",
            AsyncMock(return_value="ghs_tok"),
        ),
        patch.object(
            gh_ingest.gh_client,
            "get_branch_head_sha",
            AsyncMock(return_value="sha_v1"),
        ),
        patch.object(
            gh_ingest.gh_client, "download_repo_tarball", side_effect=_fake_download
        ),
    ):
        sb.tables["github_app_repos"].rows.append(
            {
                "tenant_id": "tenant-1",
                "installation_id": 77,
                "github_repo_id": 987654,
                "repo_full_name": "acme/demo",
                "default_branch": "develop",
                "is_private": True,
                "auto_sync_on_push": True,
                "index_status": "connected",
            }
        )
        await gh_ingest.index_github_app_repo(
            cfg,
            sb,
            None,
            tenant_id="tenant-1",
            installation_id=77,
            repo_full_name="acme/demo",
            branch="develop",
            neo4j_client=neo4j,
        )

    with (
        patch.object(
            gh_ingest.gh_client,
            "get_installation_token",
            AsyncMock(return_value="ghs_tok"),
        ),
        patch.object(
            gh_ingest.gh_client,
            "compare_commits",
            AsyncMock(
                return_value={
                    "status": "ahead",
                    "files": [{"filename": "app.py", "status": "modified"}],
                }
            ),
        ),
        patch.object(
            gh_ingest.gh_client,
            "fetch_file_at_ref",
            AsyncMock(return_value="def v2():\n    return 2\n"),
        ),
    ):
        res = await gh_ingest.update_github_app_repo_incremental(
            cfg,
            sb,
            None,
            tenant_id="tenant-1",
            installation_id=77,
            repo_full_name="acme/demo",
            head_sha="sha_v2",
            branch="develop",
            neo4j_client=neo4j,
        )

    assert res["status"] == "ok"
    assert res["mode"] == "incremental"
    assert res["source_commit"] == "sha_v2"
    row = sb.tables["github_app_repos"].rows[0]
    assert row["github_repo_id"] == 987654
    assert row["default_branch"] == "develop"
    assert row["is_private"] is True
    assert row["last_indexed_sha"] == "sha_v2"


@pytest.mark.asyncio
async def test_purge_github_app_repo_deletes_neo4j_nodes():
    neo4j = ModelNeo4jClient()
    neo4j.nodes["k1"] = ("CodeFile", {"tenant_id": "tenant-1", "repo_key": "acme/demo"})
    neo4j.nodes["k2"] = ("CodeFile", {"tenant_id": "tenant-1", "repo_key": "acme/other"})
    # Verify delete_repo_code_graph issues parameterized DETACH DELETE
    executed: list[tuple[str, dict]] = []

    class _SpyClient:
        def execute_write(self, query, params=None):
            executed.append((query, params or {}))

    await gh_ingest.purge_github_app_repo(
        "tenant-1", "acme/demo", neo4j_client=_SpyClient()
    )
    assert len(executed) == 1
    query, params = executed[0]
    assert "DETACH DELETE n" in query
    assert params == {"tenant_id": "tenant-1", "repo_key": "acme/demo"}


@pytest.mark.asyncio
async def test_incremental_update_refreshes_dependencies_snapshot_on_manifest_change():
    sb = _FakeSupabase()
    neo4j = ModelNeo4jClient()
    cfg = SimpleNamespace(github_app_max_repo_mb=10)
    archive = _make_tarball(
        {
            "app.py": "def v1():\n    return 1\n",
            "package.json": '{"dependencies": {"lodash": "4.17.20"}}',
            "pyproject.toml": '[project]\nname = "demo"\ndependencies = ["requests==2.31.0"]\n',
            "sub/package.json": '{"dependencies": {"axios": "1.6.0"}}',
        }
    )

    async def _fake_download(token, repo_full_name, ref, dest_dir: Path, max_bytes=0):
        from backend.services.github_app_client import _safe_extract_tarball

        _safe_extract_tarball(archive, dest_dir)

    with (
        patch.object(
            gh_ingest.gh_client,
            "get_installation_token",
            AsyncMock(return_value="ghs_tok"),
        ),
        patch.object(
            gh_ingest.gh_client,
            "get_branch_head_sha",
            AsyncMock(return_value="sha_v1"),
        ),
        patch.object(
            gh_ingest.gh_client, "download_repo_tarball", side_effect=_fake_download
        ),
    ):
        await gh_ingest.index_github_app_repo(
            cfg,
            sb,
            None,
            tenant_id="tenant-1",
            installation_id=77,
            repo_full_name="acme/demo",
            branch="main",
            neo4j_client=neo4j,
        )

    async def _fake_fetch(token, repo_full_name, rel_path, ref):
        if rel_path == "package.json":
            return '{"dependencies": {"lodash": "4.17.21"}}'
        return None

    with (
        patch.object(
            gh_ingest.gh_client,
            "get_installation_token",
            AsyncMock(return_value="ghs_tok"),
        ),
        patch.object(
            gh_ingest.gh_client,
            "compare_commits",
            AsyncMock(
                return_value={
                    "status": "ahead",
                    "files": [
                        {"filename": "package.json", "status": "modified"},
                        {"filename": "pyproject.toml", "status": "removed"},
                    ],
                }
            ),
        ),
        patch.object(
            gh_ingest.gh_client,
            "fetch_file_at_ref",
            side_effect=_fake_fetch,
        ),
    ):
        res = await gh_ingest.update_github_app_repo_incremental(
            cfg,
            sb,
            None,
            tenant_id="tenant-1",
            installation_id=77,
            repo_full_name="acme/demo",
            head_sha="sha_v2",
            branch="main",
            neo4j_client=neo4j,
        )

    assert res["status"] == "ok"
    snap = sb.tables["github_app_repos"].rows[0]["dependencies_snapshot"]
    by_key = {(d["source_file"], d["name"]): d["version"] for d in snap}
    assert by_key == {
        ("package.json", "lodash"): "4.17.21",
        ("sub/package.json", "axios"): "1.6.0",
    }
