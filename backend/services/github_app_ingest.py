"""Zero-retention ephemeral GitHub App repository indexing & incremental sync.

Downloads repository archives or changed files into an ephemeral temporary
directory, runs Repo X-Ray AST parsing (``backend.ingestion.code_graph``)
into Neo4j under ``repo_key = "owner/repo"`` and ``kind = "github_app"``,
and deletes the temporary directory immediately in ``finally:``.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import tempfile
import zlib
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import sentry_sdk

_orjson: Any = None
try:
    import orjson as _orjson
except ImportError:  # pragma: no cover - fallback when optional orjson absent
    _orjson = None


def _dumps_json_bytes(obj: Any) -> bytes:
    if _orjson is not None:
        return _orjson.dumps(obj)
    return json.dumps(obj).encode("utf-8")


def _loads_json_bytes(raw: bytes | str) -> Any:
    if _orjson is not None:
        return _orjson.loads(raw)
    return json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)

from backend.ingestion.code_graph import (
    apply_incremental_files,
    collect_parseable_files,
    delete_repo_code_graph,
    graph_from_payload,
    load_stored_code_graph,
    parse_repo,
    plan_incremental_update,
    read_index_meta,
    write_code_graph,
    write_index_meta,
    write_repo_code_graph_with_key,
)
from backend.ingestion.merkle import compute_repo_merkle, diff_merkle_hashes
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


async def _report_progress(
    redis_client: Any,
    tenant_id: str,
    repo_full_name: str,
    stage: str,
    message: str,
) -> None:
    """Best-effort write of current indexing stage to Redis for SSE/polling."""
    if redis_client is None:
        return
    try:
        await redis_client.setex(
            f"ghapp:progress:{tenant_id}:{repo_full_name}",
            1800,
            json.dumps({"stage": stage, "message": message}),
        )
    except Exception as exc:
        logger.debug("Progress update skipped: %s", exc)


def _make_threadsafe_progress_cb(
    loop: asyncio.AbstractEventLoop,
    redis_client: Any,
    tenant_id: str,
    repo_full_name: str,
):
    def _cb(stage: str, message: str) -> None:
        try:
            asyncio.run_coroutine_threadsafe(
                _report_progress(redis_client, tenant_id, repo_full_name, stage, message),
                loop,
            )
        except Exception as exc:
            logger.debug("Threadsafe progress dispatch skipped: %s", exc)

    return _cb


async def _load_merkle_state(
    redis_client: Any, tenant_id: str, repo_full_name: str
) -> tuple[str | None, dict[str, str]]:
    if redis_client is None:
        return None, {}
    try:
        raw = await redis_client.get(f"ghapp:merkle:{tenant_id}:{repo_full_name}")
        if not raw:
            return None, {}
        data = json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else str(raw))
        return data.get("merkle_root"), dict(data.get("file_hashes") or {})
    except Exception:
        return None, {}


async def _save_merkle_state(
    redis_client: Any,
    tenant_id: str,
    repo_full_name: str,
    merkle_root: str,
    file_hashes: dict[str, str],
) -> None:
    if redis_client is None:
        return
    try:
        await redis_client.setex(
            f"ghapp:merkle:{tenant_id}:{repo_full_name}",
            86400 * 7,
            json.dumps({"merkle_root": merkle_root, "file_hashes": file_hashes}),
        )
    except Exception as exc:
        logger.debug("Merkle state save skipped: %s", exc)


async def _load_shared_graph(
    redis_client: Any, repo_full_name: str, merkle_root: str
):
    if redis_client is None or not merkle_root:
        return None
    try:
        raw = await redis_client.get(
            f"ghapp:merkle_shared:{repo_full_name}:{merkle_root}"
        )
        if not raw:
            return None
        if isinstance(raw, bytes):
            try:
                raw_payload: bytes | str = zlib.decompress(raw)
            except zlib.error:
                raw_payload = raw
        else:
            raw_payload = str(raw)
        data = _loads_json_bytes(raw_payload)
        return graph_from_payload(
            data.get("nodes") or [],
            data.get("edges") or [],
            repo_key=repo_full_name,
        )
    except Exception:
        return None


async def _save_shared_graph(
    redis_client: Any, repo_full_name: str, merkle_root: str, graph: Any
) -> None:
    if redis_client is None or not merkle_root:
        return
    try:
        payload = _dumps_json_bytes(
            {
                "nodes": [
                    {
                        "label": n.label,
                        "name": n.name,
                        "qualified_name": n.qualified_name,
                        "path": n.path,
                        "line": n.line,
                        "language": n.language,
                        "resolved": n.resolved,
                        "end_line": n.end_line,
                    }
                    for n in graph.nodes
                ],
                "edges": [
                    {
                        "type": e.type,
                        "source_qn": e.source_qn,
                        "source_label": e.source_label,
                        "target_qn": e.target_qn,
                        "target_label": e.target_label,
                    }
                    for e in graph.edges
                ],
            }
        )
        compressed = zlib.compress(payload, level=6)
        if len(compressed) <= 15_000_000:
            await redis_client.setex(
                f"ghapp:merkle_shared:{repo_full_name}:{merkle_root}",
                86400,
                compressed,
            )
    except Exception as exc:
        logger.debug("Merkle state save skipped: %s", exc)


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
    force: bool = False,
) -> dict[str, Any]:
    """Ephemerally download, parse, and index ``repo_full_name`` into Neo4j."""
    existing = await asyncio.to_thread(
        gh_store.get_repo, sb, tenant_id, repo_full_name
    )
    github_repo_id = int((existing or {}).get("github_repo_id") or 0)
    target_branch = branch or (existing or {}).get("default_branch") or "main"
    is_private = bool((existing or {}).get("is_private", True))

    await _report_progress(
        redis_client, tenant_id, repo_full_name, "starting", "Checking repository…"
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
        if (
            not force
            and head_sha
            and (existing or {}).get("index_status") == "indexed"
            and (existing or {}).get("last_indexed_sha") == head_sha
        ):
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
            )
            await _report_progress(
                redis_client, tenant_id, repo_full_name, "complete", "Already up to date"
            )
            return {
                "status": "ok",
                "skipped": True,
                "reason": "up_to_date",
                "repo_key": repo_full_name,
                "source_commit": head_sha,
                "nodes_written": 0,
                "edges_written": 0,
            }

        ref = head_sha or target_branch
        max_bytes = int(getattr(config, "github_app_max_repo_mb", 100)) * 1024 * 1024
        await _report_progress(
            redis_client, tenant_id, repo_full_name, "downloading", "Downloading tarball…"
        )
        await gh_client.download_repo_tarball(
            token, repo_full_name, ref, Path(tmp_dir), max_bytes=max_bytes
        )
        client = neo4j_client or _default_neo4j_client()
        loop = asyncio.get_running_loop()
        progress_cb = _make_threadsafe_progress_cb(
            loop, redis_client, tenant_id, repo_full_name
        )

        root_path = Path(os.path.realpath(tmp_dir))
        parseable_files = await asyncio.to_thread(collect_parseable_files, root_path)
        merkle_root, file_hashes = await asyncio.to_thread(
            compute_repo_merkle, root_path, parseable_files
        )
        old_root, old_hashes = await _load_merkle_state(
            redis_client, tenant_id, repo_full_name
        )

        if (
            not force
            and old_root == merkle_root
            and (existing or {}).get("index_status") == "indexed"
        ):
            counts = {"nodes_written": 0, "edges_written": 0, "skipped": True}
        elif (
            not force
            and old_hashes
            and (existing or {}).get("index_status") == "indexed"
            and 0 < len(diff_merkle_hashes(old_hashes, file_hashes)) <= 200
        ):
            changed_paths = diff_merkle_hashes(old_hashes, file_hashes)
            await _report_progress(
                redis_client,
                tenant_id,
                repo_full_name,
                "incremental",
                f"Merkle sync ({len(changed_paths)} changed files)…",
            )
            counts = await asyncio.to_thread(
                apply_incremental_files,
                root_path,
                tenant_id=tenant_id,
                repo_key=repo_full_name,
                changed_paths=changed_paths,
                head_sha=head_sha,
                repo_root=f"github://{repo_full_name}",
                kind="github_app",
                client=client,
            )
        else:
            shared_graph = await _load_shared_graph(
                redis_client, repo_full_name, merkle_root
            )
            if shared_graph is not None:
                await _report_progress(
                    redis_client,
                    tenant_id,
                    repo_full_name,
                    "writing_graph",
                    "Reusing Merkle-cached graph…",
                )
                counts = await asyncio.to_thread(
                    write_code_graph,
                    client,
                    shared_graph,
                    tenant_id=tenant_id,
                    progress_callback=progress_cb,
                )
                await asyncio.to_thread(
                    write_index_meta,
                    client,
                    tenant_id,
                    repo_key=repo_full_name,
                    repo_root=f"github://{repo_full_name}",
                    source_commit=head_sha,
                    kind="github_app",
                )
            elif len(parseable_files) >= 2000:
                counts = await asyncio.to_thread(
                    write_repo_code_graph_with_key,
                    root_path,
                    repo_key=repo_full_name,
                    repo_root=f"github://{repo_full_name}",
                    source_commit=head_sha,
                    kind="github_app",
                    tenant_id=tenant_id,
                    client=client,
                    progress_callback=progress_cb,
                )
            else:
                graph = await asyncio.to_thread(
                    parse_repo,
                    root_path,
                    repo_key=repo_full_name,
                    progress_callback=progress_cb,
                )
                await _save_shared_graph(
                    redis_client, repo_full_name, merkle_root, graph
                )
                counts = await asyncio.to_thread(
                    write_code_graph,
                    client,
                    graph,
                    tenant_id=tenant_id,
                    progress_callback=progress_cb,
                )
                await asyncio.to_thread(
                    write_index_meta,
                    client,
                    tenant_id,
                    repo_key=repo_full_name,
                    repo_root=f"github://{repo_full_name}",
                    source_commit=head_sha,
                    kind="github_app",
                )

        await _save_merkle_state(
            redis_client, tenant_id, repo_full_name, merkle_root, file_hashes
        )
        await _report_progress(
            redis_client,
            tenant_id,
            repo_full_name,
            "dependencies",
            "Detecting dependencies…",
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
        await _report_progress(
            redis_client, tenant_id, repo_full_name, "complete", "Indexed"
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
        await _report_progress(
            redis_client, tenant_id, repo_full_name, "error", str(exc)[:120]
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
