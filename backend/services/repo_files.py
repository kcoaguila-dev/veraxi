"""Shared tenant-scoped repository file and directory reader.

Used by both the HTTP citation viewer (``routes/code_intel.py``) and
the Repo X-Ray LLM tools (``mcp_server/tools/code_tools.py``) so path
validation, tenant scoping, local scandir confinement, and GitHub App
pinned-SHA fetching live in one place.
"""

from __future__ import annotations

import asyncio
import base64
import fnmatch
import json
import logging
import os
from typing import Any

import sentry_sdk

logger = logging.getLogger(__name__)

MAX_CODE_FILE_VIEW_BYTES = 1_000_000
DEFAULT_READ_MAX_CHARS = 24_000
_TREE_CACHE_TTL_SEC = 300
_FILE_CACHE_TTL_SEC = 300

_SKIP_DIR_NAMES = frozenset({
    ".git",
    ".hg",
    ".svn",
    ".venv",
    "venv",
    "node_modules",
    "__pycache__",
    ".dart_tool",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
})


class RepoFileError(Exception):
    """Domain error with an HTTP-friendly status code."""

    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


def is_unsafe_repo_path(raw_path: str) -> bool:
    """True when a repo-relative path attempts traversal or is malformed."""
    if not raw_path or "\x00" in raw_path or os.path.isabs(raw_path):
        return True
    lowered = raw_path.lower()
    if "%2f" in lowered or "%5c" in lowered:
        return True
    if len(raw_path) >= 2 and raw_path[1] == ":" and raw_path[0].isalpha():
        return True
    parts = raw_path.replace("\\", "/").split("/")
    return ".." in parts


def normalize_rel_path(raw_path: str) -> str:
    """Normalize a clean repo-relative path to POSIX form."""
    cleaned = raw_path.strip().replace("\\", "/").strip("/")
    if cleaned == ".":
        return ""
    return cleaned


def allowed_code_roots() -> list[str]:
    """Server-controlled root directories a local repo may live under."""
    roots = [
        os.getcwd(),
        "/app/data",
        os.path.expanduser("~/Documents/book"),
        "/home/ubuntu/Documents/book",
    ]
    custom_dir = os.environ.get("DOCUMENTS_DIR")
    if custom_dir:
        roots.append(custom_dir)
    extra = os.environ.get("VERAXI_CODE_ROOTS")
    if extra:
        roots.extend(p for p in extra.split(os.pathsep) if p)
    canonical: list[str] = []
    for root in roots:
        real = os.path.realpath(root)
        if os.path.isdir(real) and real not in canonical:
            canonical.append(real)
    return canonical


def _scandir_resolve_segments(
    base_dir: str, parts: list[str], *, expect_file: bool
) -> str | None:
    """Walk ``parts`` from ``base_dir`` via ``os.scandir``; fail closed."""
    current = os.path.realpath(base_dir)
    for idx, part in enumerate(parts):
        if not part or part in (".", ".."):
            return None
        is_last = idx == len(parts) - 1
        found_path: str | None = None
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    if entry.name != part:
                        continue
                    if is_last and expect_file:
                        if entry.is_file(follow_symlinks=True):
                            found_path = entry.path
                    elif entry.is_dir(follow_symlinks=True):
                        found_path = entry.path
                    break
        except OSError:
            return None
        if found_path is None:
            return None
        real_next = os.path.realpath(found_path)
        try:
            if os.path.commonpath([current, real_next]) != current:
                return None
        except ValueError:
            return None
        current = real_next
    return current


def _candidate_repo_dirs(root: str, max_depth: int = 2, max_dirs: int = 2048) -> list[str]:
    """Bounded ``os.scandir`` descent under ``root``."""
    candidates = [root]
    frontier = [root]
    visited = 0
    for _ in range(max_depth):
        next_frontier: list[str] = []
        for current in frontier:
            try:
                with os.scandir(current) as entries:
                    subdirs = [
                        e.path
                        for e in entries
                        if e.name not in _SKIP_DIR_NAMES
                        and not e.name.startswith(".")
                        and e.is_dir(follow_symlinks=False)
                    ]
            except OSError:
                continue
            for subdir in subdirs:
                visited += 1
                if visited > max_dirs:
                    return candidates
                candidates.append(subdir)
                next_frontier.append(subdir)
        frontier = next_frontier
        if not frontier:
            break
    return candidates


def _resolve_local_root_dir(repo_root: str | None) -> str | None:
    """Validate and resolve a stored local ``repo_root`` inside allowed roots."""
    if not repo_root or repo_root.startswith("github://"):
        return None
    norm = os.path.normpath(repo_root)
    for root in allowed_code_roots():
        try:
            if os.path.commonpath([root, norm]) != root:
                continue
            rel = os.path.relpath(norm, root)
        except ValueError:
            continue
        if rel == ".":
            return root
        parts = [p for p in rel.split(os.sep) if p and p != "."]
        if any(p == ".." for p in parts):
            continue
        resolved = _scandir_resolve_segments(root, parts, expect_file=False)
        if resolved is not None:
            return resolved
    return None


def resolve_code_file_on_disk(
    rel_path: str, *, repo_root: str | None = None
) -> str | None:
    """Resolve a repo-relative path to an on-disk regular file under allowed roots."""
    clean = normalize_rel_path(rel_path)
    if not clean or is_unsafe_repo_path(clean):
        return None
    parts = clean.split("/")
    local_root = _resolve_local_root_dir(repo_root)
    if local_root is not None:
        resolved = _scandir_resolve_segments(local_root, parts, expect_file=True)
        if resolved is not None:
            return resolved
    for root in allowed_code_roots():
        for candidate in _candidate_repo_dirs(root):
            resolved = _scandir_resolve_segments(candidate, parts, expect_file=True)
            if resolved is not None:
                return resolved
    return None


def _read_local_utf8(resolved_path: str) -> str:
    try:
        size = os.path.getsize(resolved_path)
        with open(resolved_path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        raise RepoFileError(404, "Code file not found") from exc
    if size > MAX_CODE_FILE_VIEW_BYTES:
        raise RepoFileError(413, "Code file too large to view")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RepoFileError(415, "Code file is not UTF-8 text") from exc


def _default_neo4j_client():
    from backend.config import get_config
    from backend.storage.neo4j_client import Neo4jStorageClient

    return Neo4jStorageClient.from_config(get_config())


def _default_supabase():
    try:
        from backend.api_gateway import _get_supabase

        return _get_supabase()
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        return None


def _default_redis():
    try:
        from backend.api_gateway import app

        return getattr(getattr(app, "state", None), "redis", None)
    except Exception:
        return None


async def verify_tenant_repo_access(
    tenant_id: str,
    repo_key: str,
    *,
    neo4j_client: Any = None,
    supabase: Any = None,
) -> dict[str, Any] | None:
    """Verify ``tenant_id`` owns or has indexed ``repo_key`` (fail closed)."""
    if not tenant_id or not repo_key:
        return None
    from backend.ingestion.code_graph import read_index_meta

    meta: dict[str, Any] | None = None
    try:
        client = neo4j_client or _default_neo4j_client()
        meta = await asyncio.to_thread(read_index_meta, client, tenant_id, repo_key=repo_key)
    except Exception as exc:
        logger.debug("Neo4j index_meta check skipped for %s: %s", repo_key, exc)

    gh_row: dict[str, Any] | None = None
    sb = supabase if supabase is not None else _default_supabase()
    if sb is not None:
        try:
            from backend.services import github_app_store as gh_store

            gh_row = await asyncio.to_thread(gh_store.get_repo, sb, tenant_id, repo_key)
        except Exception as exc:
            logger.debug("GitHub App store check skipped for %s: %s", repo_key, exc)

    if meta is None and gh_row is None:
        return None
    return {"repo_key": repo_key, "meta": meta, "gh_repo": gh_row}


async def _fetch_github_app_file(
    tenant_id: str,
    repo_key: str,
    path: str,
    *,
    meta: dict[str, Any] | None,
    gh_repo: dict[str, Any] | None,
    redis_client: Any = None,
    config: Any = None,
) -> tuple[str | None, str]:
    """Fetch a file at pinned ``source_commit`` for a GitHub App repository."""
    if gh_repo is None:
        return None, ""
    from backend.config import get_config
    from backend.services import github_app_client as gh_client

    ref = str(
        (meta or {}).get("source_commit")
        or gh_repo.get("last_indexed_sha")
        or gh_repo.get("default_branch")
        or "main"
    )
    cache_key = f"ghapp:file:{tenant_id}:{repo_key}:{ref}:{path}"
    if redis_client is not None:
        try:
            cached = await redis_client.get(cache_key)
            if cached:
                text = cached.decode("utf-8") if isinstance(cached, bytes) else str(cached)
                return text, ref
        except Exception:
            pass

    cfg = config or get_config()
    token = await gh_client.get_installation_token(
        cfg, redis_client, int(gh_repo["installation_id"])
    )
    content = await gh_client.fetch_file_at_ref(
        token,
        repo_key,
        path,
        ref,
        max_bytes=MAX_CODE_FILE_VIEW_BYTES,
    )
    if content is not None and redis_client is not None:
        try:
            await redis_client.setex(cache_key, _FILE_CACHE_TTL_SEC, content)
        except Exception:
            pass
    return content, ref


async def _fetch_github_oauth_file(
    tenant_id: str,
    repo_key: str,
    path: str,
    *,
    supabase: Any = None,
) -> str | None:
    """Fallback for legacy GitHub OAuth-connected repos (``owner/repo``)."""
    if "/" not in repo_key:
        return None
    sb = supabase if supabase is not None else _default_supabase()
    if sb is None:
        return None
    try:
        import httpx

        from backend.config import get_config
        from backend.services.oauth_service import get_valid_access_token

        token = await get_valid_access_token(get_config(), sb, tenant_id, "github")
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        async with httpx.AsyncClient(base_url="https://api.github.com", timeout=20.0) as client:
            resp = await client.get(f"/repos/{repo_key}/contents/{path}", headers=headers)
            if resp.status_code != 200:
                return None
            data = resp.json()
            raw = data.get("content", "")
            if data.get("encoding") == "base64" and raw:
                return base64.b64decode(raw).decode("utf-8", errors="replace")
            return raw if isinstance(raw, str) else None
    except Exception:
        return None


def _slice_file_lines(
    content: str,
    *,
    start_line: int | None,
    end_line: int | None,
    max_chars: int | None,
) -> dict[str, Any]:
    """Slice 1-based line ranges and apply optional character truncation."""
    lines = content.splitlines()
    total_lines = len(lines)
    start = max(1, int(start_line)) if start_line is not None else 1
    end = min(total_lines, int(end_line)) if end_line is not None else total_lines
    if total_lines == 0:
        return {
            "content": "",
            "total_lines": 0,
            "start_line": 1,
            "end_line": 0,
            "truncated": False,
        }
    if start > total_lines:
        start = total_lines
    if end < start:
        end = start
    selected = "\n".join(lines[start - 1 : end])
    truncated = False
    if max_chars is not None and len(selected) > max_chars:
        selected = selected[:max_chars]
        truncated = True
    return {
        "content": selected,
        "total_lines": total_lines,
        "start_line": start,
        "end_line": end,
        "truncated": truncated,
    }


async def read_repo_file(
    tenant_id: str,
    repo_key: str,
    path: str,
    *,
    start_line: int | None = None,
    end_line: int | None = None,
    max_chars: int | None = DEFAULT_READ_MAX_CHARS,
    neo4j_client: Any = None,
    supabase: Any = None,
    redis_client: Any = None,
    config: Any = None,
) -> dict[str, Any]:
    """Read a UTF-8 file from a tenant-accessible repository."""
    if not path or "\x00" in path:
        raise RepoFileError(400, "path required")
    if is_unsafe_repo_path(path):
        raise RepoFileError(403, "Path traversal is forbidden")
    clean_path = normalize_rel_path(path)
    if not clean_path:
        raise RepoFileError(400, "path required")

    access = await verify_tenant_repo_access(
        tenant_id, repo_key, neo4j_client=neo4j_client, supabase=supabase
    )
    if access is None:
        raise RepoFileError(404, "Repository not indexed or inaccessible")

    meta = access["meta"]
    gh_repo = access["gh_repo"]
    redis = redis_client if redis_client is not None else _default_redis()
    is_ghapp = (meta or {}).get("kind") == "github_app" or gh_repo is not None

    content: str | None = None
    source_kind = "file"
    ref = str((meta or {}).get("source_commit") or "")

    if not is_ghapp:
        resolved = await asyncio.to_thread(
            resolve_code_file_on_disk,
            clean_path,
            repo_root=(meta or {}).get("repo_root"),
        )
        if resolved is not None:
            content = await asyncio.to_thread(_read_local_utf8, resolved)

    if content is None and gh_repo is not None:
        try:
            content, gh_ref = await _fetch_github_app_file(
                tenant_id,
                repo_key,
                clean_path,
                meta=meta,
                gh_repo=gh_repo,
                redis_client=redis,
                config=config,
            )
            if content is not None:
                source_kind = "github_app"
                ref = gh_ref
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            raise RepoFileError(404, "Code file unavailable from GitHub") from exc

    if content is None:
        resolved = await asyncio.to_thread(
            resolve_code_file_on_disk,
            clean_path,
            repo_root=(meta or {}).get("repo_root"),
        )
        if resolved is not None:
            content = await asyncio.to_thread(_read_local_utf8, resolved)
            source_kind = "file"

    if content is None:
        oauth_content = await _fetch_github_oauth_file(
            tenant_id, repo_key, clean_path, supabase=supabase
        )
        if oauth_content is not None:
            content = oauth_content
            source_kind = "github_oauth"

    if content is None:
        raise RepoFileError(404, f"File '{clean_path}' not found in '{repo_key}'")

    sliced = _slice_file_lines(
        content, start_line=start_line, end_line=end_line, max_chars=max_chars
    )
    return {
        "path": clean_path,
        "repo_key": repo_key,
        "ref": ref,
        "source": source_kind,
        "url": f"file://{clean_path}#L{sliced['start_line']}-L{sliced['end_line']}"
        if sliced["end_line"] >= sliced["start_line"]
        else f"file://{clean_path}",
        **sliced,
    }


def _list_local_entries(
    repo_root: str,
    rel_dir: str,
    *,
    pattern: str | None,
    limit: int,
) -> list[dict[str, Any]]:
    """List directory entries or pattern matches under a resolved local repo root."""
    if rel_dir:
        base = _scandir_resolve_segments(repo_root, rel_dir.split("/"), expect_file=False)
        if base is None:
            return []
    else:
        base = repo_root

    results: list[dict[str, Any]] = []
    if not pattern:
        try:
            with os.scandir(base) as entries:
                for entry in sorted(entries, key=lambda e: (not e.is_dir(), e.name.lower())):
                    if entry.name in _SKIP_DIR_NAMES:
                        continue
                    rel = f"{rel_dir}/{entry.name}" if rel_dir else entry.name
                    results.append(
                        {
                            "name": entry.name,
                            "path": rel,
                            "type": "dir" if entry.is_dir(follow_symlinks=False) else "file",
                        }
                    )
                    if len(results) >= limit:
                        break
        except OSError:
            return []
        return results

    lowered = pattern.lower()
    for root, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in _SKIP_DIR_NAMES)
        for fname in sorted(files):
            full = os.path.join(root, fname)
            rel = os.path.relpath(full, repo_root).replace(os.sep, "/")
            if fnmatch.fnmatch(rel.lower(), lowered) or lowered in rel.lower():
                results.append({"name": fname, "path": rel, "type": "file"})
                if len(results) >= limit:
                    return results
    return results


async def _get_cached_github_tree(
    tenant_id: str,
    repo_key: str,
    gh_repo: dict[str, Any],
    meta: dict[str, Any] | None,
    *,
    redis_client: Any = None,
    config: Any = None,
) -> list[dict[str, Any]]:
    """Fetch and Redis-cache the repository file tree for a GitHub App repo."""
    from backend.config import get_config
    from backend.services import github_app_client as gh_client

    ref = str(
        (meta or {}).get("source_commit")
        or gh_repo.get("last_indexed_sha")
        or gh_repo.get("default_branch")
        or "main"
    )
    cache_key = f"ghapp:tree:{tenant_id}:{repo_key}:{ref}"
    if redis_client is not None:
        try:
            cached = await redis_client.get(cache_key)
            if cached:
                raw = cached.decode("utf-8") if isinstance(cached, bytes) else str(cached)
                parsed = json.loads(raw)
                if isinstance(parsed, list):
                    return parsed
        except Exception:
            pass

    cfg = config or get_config()
    token = await gh_client.get_installation_token(
        cfg, redis_client, int(gh_repo["installation_id"])
    )
    tree = await gh_client.fetch_repo_tree_at_ref(token, repo_key, ref, recursive=True)
    if redis_client is not None and tree:
        try:
            await redis_client.setex(cache_key, _TREE_CACHE_TTL_SEC, json.dumps(tree))
        except Exception:
            pass
    return tree


def _filter_tree_entries(
    tree: list[dict[str, Any]],
    rel_dir: str,
    *,
    pattern: str | None,
    limit: int,
) -> list[dict[str, Any]]:
    """Filter a flat GitHub tree into direct children or pattern matches."""
    prefix = f"{rel_dir}/" if rel_dir else ""
    lowered = pattern.lower() if pattern else None
    results: list[dict[str, Any]] = []
    for item in tree:
        path = str(item.get("path") or "")
        if not path:
            continue
        parts = path.split("/")
        if any(p in _SKIP_DIR_NAMES for p in parts):
            continue
        if prefix and not path.startswith(prefix):
            continue
        remainder = path[len(prefix) :] if prefix else path
        if not remainder:
            continue
        if lowered:
            if item.get("type") != "file":
                continue
            if fnmatch.fnmatch(path.lower(), lowered) or lowered in path.lower():
                results.append(
                    {"name": parts[-1], "path": path, "type": "file", "size": item.get("size")}
                )
        else:
            if "/" in remainder:
                continue
            results.append(
                {
                    "name": remainder,
                    "path": path,
                    "type": item.get("type", "file"),
                    "size": item.get("size"),
                }
            )
        if len(results) >= limit:
            break
    results.sort(key=lambda e: (e.get("type") != "dir", str(e.get("name") or "").lower()))
    return results[:limit]


async def list_repo_entries(
    tenant_id: str,
    repo_key: str,
    path: str = "",
    *,
    pattern: str | None = None,
    limit: int = 80,
    neo4j_client: Any = None,
    supabase: Any = None,
    redis_client: Any = None,
    config: Any = None,
) -> dict[str, Any]:
    """List files/directories in a tenant-accessible repository."""
    clean_dir = normalize_rel_path(path)
    if clean_dir and is_unsafe_repo_path(clean_dir):
        raise RepoFileError(403, "Path traversal is forbidden")

    access = await verify_tenant_repo_access(
        tenant_id, repo_key, neo4j_client=neo4j_client, supabase=supabase
    )
    if access is None:
        raise RepoFileError(404, "Repository not indexed or inaccessible")

    meta = access["meta"]
    gh_repo = access["gh_repo"]
    redis = redis_client if redis_client is not None else _default_redis()
    capped_limit = min(max(1, int(limit)), 200)

    local_root = _resolve_local_root_dir((meta or {}).get("repo_root"))
    if local_root is not None and (meta or {}).get("kind") != "github_app":
        entries = await asyncio.to_thread(
            _list_local_entries, local_root, clean_dir, pattern=pattern, limit=capped_limit
        )
        return {"repo_key": repo_key, "path": clean_dir, "entries": entries}

    if gh_repo is not None:
        tree = await _get_cached_github_tree(
            tenant_id,
            repo_key,
            gh_repo,
            meta,
            redis_client=redis,
            config=config,
        )
        entries = _filter_tree_entries(tree, clean_dir, pattern=pattern, limit=capped_limit)
        return {"repo_key": repo_key, "path": clean_dir, "entries": entries}

    if local_root is not None:
        entries = await asyncio.to_thread(
            _list_local_entries, local_root, clean_dir, pattern=pattern, limit=capped_limit
        )
        return {"repo_key": repo_key, "path": clean_dir, "entries": entries}

    from backend.retrieval.code_queries import list_code_files

    code_files = await asyncio.to_thread(
        list_code_files,
        tenant_id=tenant_id,
        repo_key=repo_key,
        q=pattern or clean_dir or None,
        limit=capped_limit,
    )
    entries = [
        {"name": f.get("name") or f["path"].rsplit("/", 1)[-1], "path": f["path"], "type": "file"}
        for f in code_files
    ]
    return {"repo_key": repo_key, "path": clean_dir, "entries": entries}
