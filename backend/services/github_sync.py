"""GitHub repository → knowledge-graph sync.

Fetches a repository tree through the GitHub API with the tenant's
OAuth token, filters out binary/lock/vendor content, and feeds each
changed file's text into the existing ingestion pipeline
(``run_ingestion`` — the same entry the ARQ worker's
``process_ingestion_task`` uses), so the Neo4j ↔ Qdrant dual-write
linking of ADR 0002 is preserved by construction. This module never
writes to Neo4j or Qdrant directly.

Incremental sync: the last-synced git blob SHA per path is kept in the
integration's ``config["synced_repos"][repo]["files"]`` map; files
whose blob SHA is unchanged are skipped.
"""

import asyncio
import base64
import logging
from datetime import UTC, datetime

import httpx
import sentry_sdk

from backend.services import integration_store as store

logger = logging.getLogger(__name__)

GITHUB_API_BASE = "https://api.github.com"
MAX_FILE_BYTES = 200_000

_SKIPPED_DIRS = {"node_modules", "vendor", ".git", "dist", "build", "__pycache__"}
_SKIPPED_FILES = {
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "poetry.lock",
    "Cargo.lock",
    "composer.lock",
    "Gemfile.lock",
    "go.sum",
}
_BINARY_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip",
    ".gz", ".tar", ".woff", ".woff2", ".ttf", ".eot", ".mp3", ".mp4",
    ".mov", ".bin", ".exe", ".dll", ".so", ".dylib", ".class", ".pyc",
    ".wasm", ".parquet", ".npy", ".pt", ".onnx",
}


def should_ingest_file(path: str, size: int | None = None) -> bool:
    """True when a repo path is ingestible text content."""
    if size is not None and size > MAX_FILE_BYTES:
        return False
    parts = path.split("/")
    if any(part in _SKIPPED_DIRS for part in parts[:-1]):
        return False
    name = parts[-1]
    if name in _SKIPPED_FILES:
        return False
    dot = name.rfind(".")
    return not (dot > 0 and name[dot:].lower() in _BINARY_EXTENSIONS)


async def _api(token: str, path: str, **kwargs) -> httpx.Response:
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    async with httpx.AsyncClient(base_url=GITHUB_API_BASE, timeout=30.0) as client:
        response = await client.get(path, headers=headers, **kwargs)
        response.raise_for_status()
        return response


async def fetch_repo_tree(token: str, repo: str, branch: str | None = None) -> tuple[str, list[dict]]:
    """Return (branch used, blob entries) for a repository."""
    if not branch:
        repo_info = (await _api(token, f"/repos/{repo}")).json()
        branch = repo_info.get("default_branch") or "main"
    tree = (await _api(token, f"/repos/{repo}/git/trees/{branch}", params={"recursive": "1"})).json()
    blobs = [
        item
        for item in tree.get("tree", [])
        if item.get("type") == "blob" and should_ingest_file(item.get("path", ""), item.get("size"))
    ]
    return branch, blobs


async def fetch_blob_text(token: str, repo: str, sha: str) -> str:
    data = (await _api(token, f"/repos/{repo}/git/blobs/{sha}")).json()
    content = data.get("content", "")
    if data.get("encoding") == "base64" and content:
        return base64.b64decode(content).decode("utf-8", errors="replace")
    return content


async def fetch_issues_text(token: str, repo: str, limit: int = 30) -> list[tuple[str, str]]:
    """Return (source, text) pairs for recent open+closed issues."""
    resp = await _api(
        token, f"/repos/{repo}/issues", params={"state": "all", "per_page": limit}
    )
    out: list[tuple[str, str]] = []
    for issue in resp.json():
        if "pull_request" in issue:
            continue
        body = issue.get("body") or ""
        text = f"# {issue.get('title', '')}\n\n{body}"
        out.append((f"github://{repo}/issues/{issue.get('number')}", text))
    return out


def _run_ingestion_for_texts(texts: list[tuple[str, str]], tenant_id: str, schema: dict) -> int:
    """Run the existing ingestion pipeline for (source, text) pairs."""
    from backend.config import get_config
    from backend.ingestion.__main__ import run_ingestion

    config = get_config()
    ingested = 0
    for source, text in texts:
        if not text.strip():
            continue
        run_ingestion(
            config,
            text,
            schema,
            tenant_id,
            False,
            "en",
            [],
            config.llm_model_name or "gemini-2.5-flash-lite",
            800,
            150,
            source,
        )
        ingested += 1
    return ingested


async def sync_github_repo(
    sb,
    tenant_id: str,
    integration_row: dict,
    repo: str,
    branch: str | None = None,
    include_issues: bool = False,
    token: str | None = None,
    schema: dict | None = None,
) -> dict:
    """Sync one repository incrementally; returns a result summary.

    ``schema`` is the tenant's ingestion ontology (the worker loads it
    from Redis exactly like ``process_ingestion_task``). Without it the
    sync fails with a clear error rather than ingesting schema-less.
    """
    if schema is None:
        return {
            "status": "error",
            "repo": repo,
            "message": "No ontology defined for this tenant; generate a schema in settings first.",
        }
    if token is None:
        from backend.config import get_config
        from backend.services.oauth_service import get_valid_access_token

        token = await get_valid_access_token(
            get_config(), sb, tenant_id, "github"
        )
    used_branch, blobs = await fetch_repo_tree(token, repo, branch)
    config = dict(integration_row.get("config") or {})
    synced = dict(config.get("synced_repos") or {})
    repo_state = dict(synced.get(repo) or {})
    known_files: dict = dict(repo_state.get("files") or {})

    changed: list[tuple[str, str]] = []
    new_map = dict(known_files)
    for blob in blobs:
        path, sha = blob["path"], blob["sha"]
        new_map[path] = sha
        if known_files.get(path) != sha:
            changed.append((path, sha))

    texts: list[tuple[str, str]] = []
    for path, sha in changed:
        content = await fetch_blob_text(token, repo, sha)
        texts.append((f"github://{repo}/{path}", content))
    if include_issues:
        texts.extend(await fetch_issues_text(token, repo))

    ingested = 0
    if texts:
        loop = asyncio.get_running_loop()
        ingested = await loop.run_in_executor(
            None, _run_ingestion_for_texts, texts, tenant_id, schema
        )

    repo_state["files"] = new_map
    repo_state["branch"] = used_branch
    synced[repo] = repo_state
    config["synced_repos"] = synced
    store.update_integration(
        sb,
        tenant_id,
        integration_row["id"],
        config=config,
        status="connected",
        last_synced_at=datetime.now(UTC).isoformat(),
    )
    return {
        "status": "ok",
        "repo": repo,
        "branch": used_branch,
        "changed_files": len(changed),
        "ingested": ingested,
        "total_tracked": len(new_map),
    }


async def run_sync_for_integration(
    sb, tenant_id: str, integration_id: str, repos: list[str], include_issues: bool, schema: dict | None
) -> dict:
    """Entry shared by the sync route (inline) and the ARQ worker task."""
    row = store.get_integration(sb, tenant_id, integration_id)
    if not row:
        return {"status": "error", "message": "Integration not found"}
    if row.get("provider") != "github":
        return {"status": "error", "message": "Sync is only supported for GitHub integrations"}
    results = []
    for repo in repos:
        try:
            results.append(
                await sync_github_repo(
                    sb, tenant_id, row, repo, include_issues=include_issues, schema=schema
                )
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error("GitHub sync failed for %s: %s", repo, e)
            results.append({"status": "error", "repo": repo, "message": str(e)})
    return {"status": "ok", "results": results}
