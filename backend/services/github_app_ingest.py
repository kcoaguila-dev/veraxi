"""Zero-retention ephemeral GitHub App repository indexing & incremental sync.

Downloads repository archives or changed files into an ephemeral temporary
directory, runs Repo X-Ray AST parsing (``backend.ingestion.code_graph``)
into Neo4j under ``repo_key = "owner/repo"`` and ``kind = "github_app"``,
and deletes the temporary directory immediately in ``finally:``.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import sentry_sdk

from backend.ingestion.code_graph import (
    apply_incremental_files,
    delete_repo_code_graph,
    load_stored_code_graph,
    plan_incremental_update,
    read_index_meta,
    write_repo_code_graph_with_key,
)
from backend.ingestion.dependencies import (
    extract_dependencies_from_file,
    extract_dependencies_from_repo,
    is_dependency_manifest_path,
)
from backend.services import github_app_client as gh_client
from backend.services import github_app_store as gh_store

logger = logging.getLogger(__name__)

_MAX_INCREMENTAL_FILES = 250


def _default_neo4j_client():
    from backend.config import get_config
    from backend.storage.neo4j_client import Neo4jStorageClient

    return Neo4jStorageClient.from_config(get_config())


def _safe_write_temp_file(root: Path, rel_path: str, content: str) -> None:
    root_real = os.path.realpath(root)
    clean_parts = [p for p in Path(rel_path).parts if p and p != "."]
    if not clean_parts or any(p == ".." or p.startswith("/") for p in clean_parts):
        return
    target = os.path.realpath(os.path.join(root_real, *clean_parts))
    if os.path.commonpath([root_real, target]) != root_real:
        return
    os.makedirs(os.path.dirname(target), exist_ok=True)
    Path(target).write_text(content, encoding="utf-8")


def _refresh_dependencies_snapshot(
    existing_deps: list[dict[str, Any]],
    tmp_dir: str,
    changed_manifests: set[str],
    removed_paths: set[str],
) -> list[dict[str, Any]]:
    """Update persisted dependency records for manifests touched in an incremental push."""
    retained = [
        dict(rec)
        for rec in existing_deps
        if rec.get("source_file") not in changed_manifests
    ]
    root = Path(tmp_dir)
    for rel_path in sorted(changed_manifests - removed_paths):
        manifest_file = root / rel_path
        if not manifest_file.is_file():
            continue
        for rec in extract_dependencies_from_file(manifest_file):
            updated = dict(rec)
            updated["source_file"] = Path(rel_path).as_posix()
            retained.append(updated)
    retained.sort(
        key=lambda r: (
            str(r.get("source_file") or ""),
            str(r.get("name") or ""),
            str(r.get("version") or ""),
        )
    )
    return retained


async def index_github_app_repo(
    config: Any,
    sb: Any,
    redis_client: Any,
    *,
    tenant_id: str,
    installation_id: int,
    repo_full_name: str,
    branch: str | None = None,
    neo4j_client: Any = None,
) -> dict[str, Any]:
    """Ephemerally download, parse, and index ``repo_full_name`` into Neo4j."""
    existing = await asyncio.to_thread(
        gh_store.get_repo, sb, tenant_id, repo_full_name
    )
    github_repo_id = int((existing or {}).get("github_repo_id") or 0)
    target_branch = branch or (existing or {}).get("default_branch") or "main"
    is_private = bool((existing or {}).get("is_private", True))

    await asyncio.to_thread(
        gh_store.upsert_repo,
        sb,
        tenant_id,
        installation_id=installation_id,
        github_repo_id=github_repo_id,
        repo_full_name=repo_full_name,
        default_branch=target_branch,
        is_private=is_private,
        index_status="indexing",
        last_error="",
    )

    tmp_dir = tempfile.mkdtemp(prefix="veraxi-ghapp-")
    try:
        token = await gh_client.get_installation_token(
            config, redis_client, installation_id
        )
        head_sha = await gh_client.get_branch_head_sha(
            token, repo_full_name, target_branch
        )
        ref = head_sha or target_branch
        max_bytes = int(getattr(config, "github_app_max_repo_mb", 100)) * 1024 * 1024
        await gh_client.download_repo_tarball(
            token, repo_full_name, ref, Path(tmp_dir), max_bytes=max_bytes
        )
        client = neo4j_client or _default_neo4j_client()
        counts = await asyncio.to_thread(
            write_repo_code_graph_with_key,
            tmp_dir,
            repo_key=repo_full_name,
            repo_root=f"github://{repo_full_name}",
            source_commit=head_sha,
            kind="github_app",
            tenant_id=tenant_id,
            client=client,
        )
        deps = await asyncio.to_thread(extract_dependencies_from_repo, tmp_dir)
        now_iso = datetime.now(UTC).isoformat()
        await asyncio.to_thread(
            gh_store.upsert_repo,
            sb,
            tenant_id,
            installation_id=installation_id,
            github_repo_id=github_repo_id,
            repo_full_name=repo_full_name,
            default_branch=target_branch,
            is_private=is_private,
            index_status="indexed",
            last_indexed_sha=head_sha,
            last_indexed_at=now_iso,
            last_error="",
            dependencies_snapshot=deps,
        )
        return {
            "status": "ok",
            "repo_key": repo_full_name,
            "source_commit": head_sha,
            "dependencies_detected": len(deps),
            **counts,
        }
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.error(
            "GitHub App indexing failed for %s (tenant=%s): %s",
            repo_full_name,
            tenant_id,
            exc,
        )
        await asyncio.to_thread(
            gh_store.upsert_repo,
            sb,
            tenant_id,
            installation_id=installation_id,
            github_repo_id=github_repo_id,
            repo_full_name=repo_full_name,
            default_branch=target_branch,
            is_private=is_private,
            index_status="error",
            last_error=str(exc)[:300],
        )
        raise
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


async def update_github_app_repo_incremental(
    config: Any,
    sb: Any,
    redis_client: Any,
    *,
    tenant_id: str,
    installation_id: int,
    repo_full_name: str,
    head_sha: str,
    branch: str | None = None,
    neo4j_client: Any = None,
) -> dict[str, Any]:
    """Incrementally update ``repo_full_name`` using GitHub's Compare API."""
    client = neo4j_client or _default_neo4j_client()
    meta = await asyncio.to_thread(
        read_index_meta, client, tenant_id, repo_key=repo_full_name
    )
    indexed_sha = (meta or {}).get("source_commit")
    if not indexed_sha:
        return await index_github_app_repo(
            config,
            sb,
            redis_client,
            tenant_id=tenant_id,
            installation_id=installation_id,
            repo_full_name=repo_full_name,
            branch=branch,
            neo4j_client=client,
        )
    if indexed_sha == head_sha:
        return {
            "status": "ok",
            "mode": "incremental",
            "changed_files": 0,
            "repo_key": repo_full_name,
            "source_commit": head_sha,
        }

    token = await gh_client.get_installation_token(
        config, redis_client, installation_id
    )
    compare = await gh_client.compare_commits(
        token, repo_full_name, indexed_sha, head_sha
    )
    files = compare.get("files") or []
    if compare.get("status") == "diverged" or len(files) > _MAX_INCREMENTAL_FILES:
        return await index_github_app_repo(
            config,
            sb,
            redis_client,
            tenant_id=tenant_id,
            installation_id=installation_id,
            repo_full_name=repo_full_name,
            branch=branch,
            neo4j_client=client,
        )

    changed_paths: set[str] = set()
    removed_paths: set[str] = set()
    for entry in files:
        filename = entry.get("filename")
        if not filename:
            continue
        changed_paths.add(filename)
        if entry.get("status") == "removed":
            removed_paths.add(filename)
        prev = entry.get("previous_filename")
        if prev:
            changed_paths.add(prev)
            removed_paths.add(prev)

    if not changed_paths:
        return {
            "status": "ok",
            "mode": "incremental",
            "changed_files": 0,
            "repo_key": repo_full_name,
            "source_commit": head_sha,
        }

    stored = await asyncio.to_thread(
        load_stored_code_graph, client, tenant_id, repo_key=repo_full_name
    )
    reparse_paths = plan_incremental_update(stored, changed_paths)
    changed_manifests = {p for p in changed_paths if is_dependency_manifest_path(p)}
    fetch_paths = sorted(
        (reparse_paths | changed_manifests) - removed_paths
    )

    tmp_dir = tempfile.mkdtemp(prefix="veraxi-ghapp-inc-")
    try:
        sem = asyncio.Semaphore(8)

        async def _fetch_one(rel_path: str) -> None:
            async with sem:
                try:
                    text = await gh_client.fetch_file_at_ref(
                        token, repo_full_name, rel_path, head_sha
                    )
                except gh_client.GitHubAppError:
                    return
                except Exception as exc:
                    logger.debug("Skipping %s during incremental fetch: %s", rel_path, exc)
                    return
                if text is not None:
                    _safe_write_temp_file(Path(tmp_dir), rel_path, text)

        await asyncio.gather(*(_fetch_one(p) for p in fetch_paths))
        counts = await asyncio.to_thread(
            apply_incremental_files,
            tmp_dir,
            tenant_id=tenant_id,
            repo_key=repo_full_name,
            changed_paths=changed_paths,
            head_sha=head_sha,
            repo_root=f"github://{repo_full_name}",
            kind="github_app",
            client=client,
        )
        updated_deps: list[dict[str, Any]] | None = None
        if changed_manifests:
            existing_row = await asyncio.to_thread(
                gh_store.get_repo, sb, tenant_id, repo_full_name
            )
            existing_deps = list((existing_row or {}).get("dependencies_snapshot") or [])
            updated_deps = _refresh_dependencies_snapshot(
                existing_deps, tmp_dir, changed_manifests, removed_paths
            )
        await asyncio.to_thread(
            gh_store.update_repo_index_status,
            sb,
            tenant_id,
            repo_full_name,
            index_status="indexed",
            last_indexed_sha=head_sha,
            last_indexed_at=datetime.now(UTC).isoformat(),
            last_error="",
            dependencies_snapshot=updated_deps,
        )
        return {"status": "ok", **counts}
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


async def purge_github_app_repo(
    tenant_id: str, repo_full_name: str, *, neo4j_client: Any = None
) -> None:
    """Remove all Neo4j code-graph nodes for a disconnected/removed GitHub App repo."""
    client = neo4j_client or _default_neo4j_client()
    await asyncio.to_thread(
        delete_repo_code_graph, client, tenant_id, repo_full_name
    )
