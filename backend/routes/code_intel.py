"""Repo X-Ray & Vuln Intel endpoints (Evidence-First GUI Phase 3).

Follows the ``routes/usage.py`` / ``routes/memories.py`` registration
pattern. The work itself lives in ``backend.ingestion.code_graph``,
``backend.retrieval.code_queries``, ``backend.ingestion.vuln_intel``,
``backend.ingestion.dependencies`` and
``backend.retrieval.vuln_queries`` — this module is the HTTP boundary:
path validation, error mapping and Sentry reporting.

Security: ``repo_path`` is never trusted. It must resolve (via an
``os.scandir`` segment walk from an untainted root) inside one of
the allowed roots — the same roots
``routes/files.py`` serves documents from, plus any roots the
operator lists in ``VERAXI_CODE_ROOTS`` (``os.pathsep``-separated).
The scandir-based ``_resolve_inside_allowed_dirs`` helper used by
``routes/files.py`` resolves *files* only (its final segment must be
a file), so directory targets are validated here with the same
fail-closed semantics: null bytes, ``..`` segments and anything
outside the allowed roots are rejected before any filesystem walk.
"""

import asyncio
import hashlib
import hmac
import json
import logging
import os
from typing import Any

import sentry_sdk
from fastapi import Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from backend.ingestion.code_graph import (
    MAX_INGEST_EDGES,
    MAX_INGEST_NODES,
    derive_repo_key,
    find_index_meta_for_root,
    git_origin_repo,
    git_pull_ff_only,
    update_repo_code_graph,
    write_parsed_code_graph,
    write_repo_code_graph,
)
from backend.ingestion.dependencies import extract_dependencies_from_repo
from backend.ingestion.vuln_intel import (
    apply_kev,
    fetch_and_write_vuln_intel,
    fetch_kev_records,
    fetch_osv_for_packages,
)
from backend.retrieval.code_queries import (
    impact_analysis,
    indexed_file,
    repo_overview,
    symbol_lookup,
)
from backend.retrieval.vuln_queries import build_vuln_report, vuln_report

logger = logging.getLogger(__name__)


def _allowed_roots() -> list[str]:
    """Directories a repo_path may live under (files.py roots + env)."""
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


def _is_traversal_input(raw_path: str) -> bool:
    lowered = raw_path.lower()
    if "%2f" in lowered or "%5c" in lowered:
        return True
    parts = raw_path.replace("\\", "/").split("/")
    return ".." in parts


def _relative_segments_under_root(raw_path: str, root: str) -> list[str] | None:
    """Return clean segment names if raw_path lexically targets inside root."""
    normalized = (
        os.path.normpath(raw_path)
        if os.path.isabs(raw_path)
        else os.path.normpath(os.path.join(os.getcwd(), raw_path))
    )
    try:
        if os.path.commonpath([root, normalized]) != root:
            return None
        rel = os.path.relpath(normalized, root)
    except ValueError:
        return None
    if rel == ".":
        return []
    parts = [p for p in rel.split(os.sep) if p and p != "."]
    return None if any(p == ".." for p in parts) else parts


def _find_subdir_entry(current_dir: str, name: str) -> str | None:
    """Return the untainted scandir entry path matching name, or None."""
    try:
        with os.scandir(current_dir) as entries:
            for entry in entries:
                if entry.name == name and entry.is_dir(follow_symlinks=True):
                    return entry.path
    except OSError:
        return None
    return None


def _walk_repo_segments(root: str, parts: list[str]) -> str | None:
    """Walk segments from untainted root via os.scandir; verify confinement."""
    current = root
    for part in parts:
        next_path = _find_subdir_entry(current, part)
        if next_path is None:
            return None
        real_next = os.path.realpath(next_path)
        try:
            if os.path.commonpath([root, real_next]) != root:
                raise HTTPException(
                    status_code=403,
                    detail="Repository path is outside the allowed roots",
                )
        except ValueError as exc:
            raise HTTPException(
                status_code=403,
                detail="Repository path is outside the allowed roots",
            ) from exc
        current = real_next
    return current


def _validate_repo_path(raw_path: str) -> str:
    """Resolve ``raw_path`` to an existing directory inside the roots.

    Raises HTTPException 400 for malformed input, 403 for paths that
    try to escape the allowed roots, 404 for missing directories.
    """
    if not raw_path or "\x00" in raw_path:
        raise HTTPException(status_code=400, detail="repo_path required")
    if _is_traversal_input(raw_path):
        raise HTTPException(status_code=403, detail="Path traversal is forbidden")
    matched_any_root = False
    for root in _allowed_roots():
        parts = _relative_segments_under_root(raw_path, root)
        if parts is None:
            continue
        matched_any_root = True
        resolved = _walk_repo_segments(root, parts)
        if resolved is not None:
            return resolved
    if matched_any_root:
        raise HTTPException(status_code=404, detail="Repository path not found")
    raise HTTPException(
        status_code=403, detail="Repository path is outside the allowed roots"
    )


# Viewer cap for GET /api/v1/code/file: citations point at parsed
# source files (ingestion already skips files past 200 KB), so 1 MB
# leaves generous headroom while keeping a hostile or accidental
# request from streaming an unbounded body into the viewer.
MAX_CODE_FILE_VIEW_BYTES = 1_000_000

# Directories never descended into while locating an ingested repo
# under an allowed root: VCS metadata, dependency/vendor trees and
# tool caches. Hidden directories (dot-prefixed) are skipped too.
_REPO_SEARCH_SKIP_DIRS = {
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
}
_MAX_REPO_SEARCH_DIRS = 2048
_MAX_REPO_SEARCH_DEPTH = 2


def _is_code_file_traversal(raw_path: str) -> bool:
    """True when a cited code path tries to escape the allowed roots.

    Mirrors the fail-closed semantics of ``routes/files.py`` for the
    document endpoint: null bytes, absolute paths, encoded separators
    and ``..`` segments are traversal attempts (403), never servable
    files.
    """
    if "\x00" in raw_path or os.path.isabs(raw_path):
        return True
    return _is_traversal_input(raw_path)


def _candidate_repo_dirs(root: str) -> list[str]:
    """Root itself plus subdirectories found by a bounded scandir descent.

    Repos are ingested from directories *under* the allowed roots, so
    a cited repo-relative path may live one or two levels below a
    root. Only untainted ``os.scandir`` entry paths are returned, and
    the walk is capped so a huge tree cannot make it unbounded.
    """
    candidates = [root]
    frontier = [root]
    visited = 0
    for _depth in range(_MAX_REPO_SEARCH_DEPTH):
        next_frontier: list[str] = []
        for current in frontier:
            try:
                with os.scandir(current) as entries:
                    subdirs = [
                        entry.path
                        for entry in entries
                        if entry.name not in _REPO_SEARCH_SKIP_DIRS
                        and not entry.name.startswith(".")
                        and entry.is_dir(follow_symlinks=False)
                    ]
            except OSError:
                continue
            for subdir in subdirs:
                visited += 1
                if visited > _MAX_REPO_SEARCH_DIRS:
                    return candidates
                candidates.append(subdir)
                next_frontier.append(subdir)
        frontier = next_frontier
        if not frontier:
            break
    return candidates


def _resolve_code_file_on_disk(rel_path: str) -> str | None:
    """Resolve a repo-relative code path to an on-disk file, or None.

    Every candidate repo directory is tried through the shared
    scandir resolver, so the path that reaches ``open()`` is built
    from directory entries under a server-controlled root — the
    same discipline as ``routes/files.py`` document serving.
    """
    from backend.mcp_server.handlers.tool_registry import (
        _resolve_inside_allowed_dirs,
    )

    for root in _allowed_roots():
        for candidate_dir in _candidate_repo_dirs(root):
            resolved = _resolve_inside_allowed_dirs(rel_path, [candidate_dir])
            if resolved is not None:
                return resolved
    return None


def _read_code_file_text(resolved_path: str) -> str:
    """Read a resolved code file as UTF-8 text, failing closed.

    Raises HTTPException 404 if the file vanished after resolution,
    413 past the viewer size cap, and 415 for content that is not
    UTF-8 text (a code citation never legitimately points at a
    binary file, and serving one would be garbage in the viewer).
    """
    try:
        size = os.path.getsize(resolved_path)
        with open(resolved_path, "rb") as fh:
            raw = fh.read()
    except OSError as e:
        raise HTTPException(status_code=404, detail="Code file not found") from e
    if size > MAX_CODE_FILE_VIEW_BYTES:
        raise HTTPException(status_code=413, detail="Code file too large to view")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as e:
        raise HTTPException(
            status_code=415, detail="Code file is not UTF-8 text"
        ) from e


class CodeIngestRequest(BaseModel):
    repo_path: str


class CodeIngestGraphRequest(BaseModel):
    repo_name: str
    nodes: list[dict] = []
    edges: list[dict] = []
    # Optional client-reported provenance: the parsing client runs
    # where the repo lives, so its git HEAD is stamped into the index
    # metadata verbatim (see code_graph.write_index_meta). Absent =
    # unknown, never guessed server-side.
    source_commit: str | None = None


class VulnReportRequest(BaseModel):
    repo_path: str | None = None
    dependencies: list[dict] | None = None
    sbom_json: dict | None = None
    include_reachability: bool = False
    # Optional repo key scoping code reachability to one indexed
    # repo when the tenant has several (see code_queries).
    repo: str | None = None
    # Opt-in live OSV.dev fallback: only consulted when the tenant
    # graph yields no findings (e.g. no OSV packages synced yet).
    # Off by default so a report never makes surprise network calls.
    live_osv: bool = False


class SarifIngestRequest(BaseModel):
    sarif: dict


class AttackSyncRequest(BaseModel):
    stix_json: dict | None = None


class ReconIngestRequest(BaseModel):
    nuclei: str | list[dict]


class AlertIngestRequest(BaseModel):
    alerts: dict | list[dict]


class ScipIngestRequest(BaseModel):
    scip: dict


def _default_neo4j_client():
    """Build the production Neo4j storage client from config.

    Same construction ``code_graph.write_repo_code_graph`` uses when
    no client is injected (``Neo4jStorageClient.from_config``).
    """
    from backend.config import get_config
    from backend.storage.neo4j_client import Neo4jStorageClient

    return Neo4jStorageClient.from_config(get_config())


def _live_osv_report(
    dependencies: list[dict],
    tenant_id: str,
    include_reachability: bool = False,
    repo: str | None = None,
) -> dict:
    """Build a report from a live OSV.dev batch lookup (no graph writes).

    KEV enrichment is best-effort: if the KEV feed cannot be fetched,
    the OSV findings are returned without KEV flags rather than
    failing the report.
    """
    from backend.ingestion.dependencies import normalize_package_name
    from backend.ingestion.vuln_intel import apply_epss, fetch_epss_scores

    records = fetch_osv_for_packages(dependencies)
    try:
        apply_kev(records, fetch_kev_records())
    except Exception as exc:  # KEV is enrichment only
        logger.warning("KEV enrichment for live OSV report failed: %s", exc)
    cve_ids = [
        cid
        for r in records
        for cid in [r.id, *r.aliases]
        if (cid or "").upper().startswith("CVE-")
    ]
    if cve_ids:
        try:
            apply_epss(records, fetch_epss_scores(cve_ids))
        except Exception as exc:  # EPSS is enrichment only
            logger.warning("EPSS enrichment for live OSV report failed: %s", exc)
    index: dict[str, list[dict]] = {}
    for record in records:
        for affected in record.affected:
            ecosystem = (affected.ecosystem or "").lower()
            entry = {
                "cve_id": record.id,
                "advisory_id": record.id,
                "severity": record.severity,
                "kev": bool(record.kev),
                "epss_score": record.epss_score,
                "epss_percentile": record.epss_percentile,
                "cwe_ids": list(record.cwe_ids),
                **affected.properties(),
            }
            name = normalize_package_name(affected.product)
            index.setdefault(name, []).append(entry)
            if ecosystem and ecosystem != "cpe":
                index.setdefault(f"{ecosystem}:{name}", []).append(entry)
            # Maven OSV names are "group:artifact" while dependency
            # lists often carry just the artifact ("log4j-core").
            if ":" in name:
                artifact = normalize_package_name(name.rsplit(":", 1)[-1])
                index.setdefault(artifact, []).append(entry)
                if ecosystem and ecosystem != "cpe":
                    index.setdefault(f"{ecosystem}:{artifact}", []).append(entry)
    report = build_vuln_report(dependencies, index)
    if include_reachability:
        from backend.retrieval.vuln_queries import attach_code_reachability

        attach_code_reachability(report["findings"], tenant_id=tenant_id, repo=repo)
    report["tenant_id"] = tenant_id
    report["source"] = "osv_live"
    return report


def _write_parsed_graph(payload: CodeIngestGraphRequest, tenant_id: str) -> dict:
    """Write a pre-parsed graph payload through the ingestion writer."""
    return write_parsed_code_graph(
        _default_neo4j_client(),
        payload.nodes,
        payload.edges,
        tenant_id=tenant_id,
        repo_name=payload.repo_name,
        source_commit=payload.source_commit,
    )


def _write_scip(payload: ScipIngestRequest, tenant_id: str) -> dict:
    """Parse a SCIP payload and write it through the ingestion writer."""
    from backend.ingestion.scip_ingest import write_scip_graph

    return write_scip_graph(
        _default_neo4j_client(), payload.scip, tenant_id=tenant_id
    )


def _resolve_webhook_checkout(full_name: str) -> str | None:
    """Find the local checkout for a pushed ``owner/repo``, or None.

    Candidates are the allowed code roots themselves plus their
    immediate subdirectories (repos live one level below a root, the
    same layout the code-file endpoint scans). A candidate matches
    when its git origin slug equals ``full_name``; failing that, when
    its directory name equals the repo part of ``full_name``.
    """
    repo_name = full_name.rsplit("/", 1)[-1]
    candidates: list[str] = []
    for root in _allowed_roots():
        candidates.append(root)
        try:
            with os.scandir(root) as entries:
                for entry in entries:
                    if entry.name.startswith("."):
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        candidates.append(entry.path)
        except OSError:
            continue
    by_name: str | None = None
    for candidate in candidates:
        if git_origin_repo(candidate) == full_name:
            return os.path.realpath(candidate)
        if by_name is None and os.path.basename(candidate) == repo_name:
            by_name = os.path.realpath(candidate)
    return by_name


def _sync_vuln_intel(tenant_id: str) -> dict:
    """Fetch NVD + CISA KEV and write them for ``tenant_id``.

    The NVD API key, when configured, comes from the ``NVD_API_KEY``
    environment variable inside ``fetch_and_write_vuln_intel``.
    """
    qdrant_client = None
    try:
        from backend.config import get_config
        from backend.storage.qdrant_client import QdrantStorageClient

        qdrant_client = QdrantStorageClient.from_config(get_config())
    except Exception as exc:
        logger.warning("Qdrant unavailable during vuln sync; skipping vector indexing: %s", exc)
    return fetch_and_write_vuln_intel(
        _default_neo4j_client(), tenant_id=tenant_id, qdrant_client=qdrant_client
    )


def register_code_intel_routes(
    app_router, get_tenant_id, _get_supabase=None, config=None
):
    """Register Repo X-Ray and Vuln Intel routes."""

    @app_router.post("/api/v1/code/ingest")
    async def ingest_code_graph(
        payload: CodeIngestRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Parse a repo into the code graph for this tenant."""
        resolved = _validate_repo_path(payload.repo_path)
        try:
            counts = await asyncio.to_thread(
                write_repo_code_graph, resolved, tenant_id=tenant_id
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to index code graph"
            ) from e
        return {"status": "ok", "repo_path": resolved, **counts}

    @app_router.post("/api/v1/code/update")
    async def update_code_graph(
        payload: CodeIngestRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Incrementally refresh a previously indexed repo.

        Diffs the index stamp's commit against the checkout and
        re-parses only the changed files (falling back to a full
        re-parse when the incremental inputs are unavailable — see
        ``code_graph.update_repo_code_graph``). The response carries
        ``mode`` ("incremental" / "full") and the change counts.
        """
        resolved = _validate_repo_path(payload.repo_path)
        try:
            counts = await asyncio.to_thread(
                update_repo_code_graph, resolved, tenant_id=tenant_id
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to update code graph"
            ) from e
        return {"status": "ok", "repo_path": resolved, **counts}

    @app_router.post("/api/v1/code/github-webhook")
    async def github_push_webhook(request: Request):
        """Trigger a code-graph update on a GitHub push.

        Thin by design: verify, resolve, sync, delegate. The
        signature is checked with HMAC-SHA256 against
        ``GITHUB_WEBHOOK_SECRET`` when that env var is configured
        (invalid signatures are rejected with 401); when no secret
        is configured the payload is accepted with a warning logged
        — deployments that expose this route publicly must set the
        secret. Resolution: the pushed repo is matched to a local
        checkout under the code roots (by origin remote slug, then
        by directory name); a push with no matching checkout is
        answered 202 with ``status: "unresolved"`` and changes
        nothing (the webhook never clones — it holds no credentials
        for the repo host).

        Before updating, the checkout is synced toward the pushed
        commit with a fast-forward-only pull (see
        ``code_graph.git_pull_ff_only``): it runs only on a clean
        working tree and never discards local changes; the response
        carries the outcome as ``pull: {"pulled", "head", "reason"}``
        either way. The tenant(s) to update come from the index
        metadata stamped for that checkout at ingestion time — there
        is no separate repo ↔ tenant registry to consult. A checkout
        that resolves but was never indexed is fully indexed on this
        first push, under the ``default`` tenant (the tenant the
        query layer defaults to), and the response says so with
        ``status: "indexed"``.
        """
        payload_bytes = await request.body()
        secret = os.environ.get("GITHUB_WEBHOOK_SECRET")
        if secret:
            signature = request.headers.get("x-hub-signature-256") or ""
            expected = (
                "sha256="
                + hmac.new(
                    secret.encode("utf-8"), payload_bytes, hashlib.sha256
                ).hexdigest()
            )
            if not hmac.compare_digest(signature, expected):
                raise HTTPException(status_code=401, detail="Invalid webhook signature")
        else:
            logger.warning(
                "GITHUB_WEBHOOK_SECRET is not configured; "
                "accepting an unsigned GitHub webhook payload"
            )
        event = request.headers.get("x-github-event")
        if event != "push":
            return {"status": "ignored", "event": event}
        try:
            payload = json.loads(payload_bytes)
        except (ValueError, UnicodeDecodeError) as e:
            raise HTTPException(status_code=400, detail="Invalid JSON payload") from e
        repository = payload.get("repository") or {}
        full_name = repository.get("full_name")
        if not full_name:
            raise HTTPException(status_code=400, detail="Payload has no repository.full_name")
        checkout = _resolve_webhook_checkout(str(full_name))
        if checkout is None:
            return JSONResponse(
                status_code=202,
                content={
                    "status": "unresolved",
                    "repo": full_name,
                    "reason": "no local checkout under the code roots",
                },
            )
        after = payload.get("after")
        pull = await asyncio.to_thread(
            git_pull_ff_only, checkout, str(after) if after else None
        )
        client = _default_neo4j_client()
        metas = await asyncio.to_thread(find_index_meta_for_root, client, checkout)
        tenants = sorted({m["tenant_id"] for m in metas if m.get("tenant_id")})
        if not tenants:
            # First push for a known checkout: index it in full so
            # later pushes take the incremental path.
            try:
                counts = await asyncio.to_thread(
                    write_repo_code_graph,
                    checkout,
                    tenant_id="default",
                    client=client,
                )
            except Exception as e:
                sentry_sdk.capture_exception(e)
                return JSONResponse(
                    status_code=202,
                    content={
                        "status": "unresolved",
                        "repo": full_name,
                        "reason": "checkout could not be indexed",
                        "pull": pull,
                    },
                )
            return {
                "status": "indexed",
                "repo": full_name,
                "after": after,
                "pull": pull,
                "indexed": {
                    "tenant_id": "default",
                    "repo_key": derive_repo_key(checkout),
                    **counts,
                },
            }
        updates: dict[str, Any] = {}
        for tenant_id in tenants:
            try:
                updates[tenant_id] = await asyncio.to_thread(
                    update_repo_code_graph,
                    checkout,
                    tenant_id=tenant_id,
                    client=client,
                )
            except Exception as e:
                sentry_sdk.capture_exception(e)
                updates[tenant_id] = {"error": "update failed"}
        return {
            "status": "ok",
            "repo": full_name,
            "after": after,
            "pull": pull,
            "updates": updates,
        }

    @app_router.post("/api/v1/code/ingest-graph")
    async def ingest_parsed_code_graph(
        payload: CodeIngestGraphRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Persist a client-parsed code graph (CLI ``xray index --local``).

        The client parses a repo the server cannot read; node/edge
        labels are whitelist-validated in ``code_graph`` and every
        write is parameterized and tenant-scoped, exactly like the
        server-side ingest path.
        """
        if len(payload.nodes) > MAX_INGEST_NODES or len(payload.edges) > MAX_INGEST_EDGES:
            raise HTTPException(
                status_code=413, detail="Code graph payload too large"
            )
        try:
            counts = await asyncio.to_thread(
                _write_parsed_graph, payload, tenant_id
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to ingest code graph"
            ) from e
        return {"status": "ok", "repo_name": payload.repo_name, **counts}

    @app_router.post("/api/v1/code/ingest-scip")
    async def ingest_scip_graph(
        payload: ScipIngestRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Persist a SCIP index (``scip print --json`` output).

        The payload is the parsed JSON document (``documents[]`` with
        occurrences/symbols); parsing is stdlib-only in
        ``backend.ingestion.scip_ingest`` and persistence reuses the
        same tenant-scoped, whitelist-validated code-graph writer as
        the other ingest paths. Graphs exceeding the ingest node/edge
        bounds are rejected with 413.
        """
        documents = payload.scip.get("documents")
        if not isinstance(documents, list):
            raise HTTPException(
                status_code=400, detail="SCIP payload must contain a documents list"
            )
        raw_items = sum(
            len(doc.get("occurrences") or []) + len(doc.get("symbols") or [])
            for doc in documents
            if isinstance(doc, dict)
        )
        if raw_items > MAX_INGEST_NODES + MAX_INGEST_EDGES:
            raise HTTPException(status_code=413, detail="SCIP payload too large")
        try:
            counts = await asyncio.to_thread(_write_scip, payload, tenant_id)
        except ValueError as e:
            raise HTTPException(
                status_code=413, detail="SCIP payload too large"
            ) from e
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to ingest SCIP index"
            ) from e
        return {"status": "ok", **counts}

    @app_router.get("/api/v1/code/overview")
    async def get_code_overview(
        repo: str | None = None, tenant_id: str = Depends(get_tenant_id)
    ):
        """Node/edge counts plus the most-connected symbols.

        ``repo`` (a repo key) scopes the overview to one indexed
        repo when the tenant has several.
        """
        try:
            return await asyncio.to_thread(
                repo_overview, tenant_id=tenant_id, repo=repo
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to load code overview"
            ) from e

    @app_router.get("/api/v1/code/symbol")
    async def get_code_symbol(
        name: str = "",
        repo: str | None = None,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Look up a code symbol by qualified or simple name."""
        try:
            return await asyncio.to_thread(
                symbol_lookup, name, tenant_id=tenant_id, repo=repo
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to look up symbol"
            ) from e

    @app_router.get("/api/v1/code/impact")
    async def get_code_impact(
        symbol: str = "",
        max_depth: int = 3,
        repo: str | None = None,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Reverse-dependency impact tree for a symbol."""
        try:
            return await asyncio.to_thread(
                impact_analysis,
                symbol,
                tenant_id=tenant_id,
                max_depth=max_depth,
                repo=repo,
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to run impact analysis"
            ) from e

    @app_router.get("/api/v1/code/file")
    async def get_code_file(
        path: str = "", tenant_id: str = Depends(get_tenant_id)
    ):
        """Serve one indexed code file's content for citation viewing.

        ``path`` is the repo-relative path carried by line-anchored
        code citations (``file://<path>#L<start>-L<end>``). A file is
        served only when the tenant's own code graph holds a CodeFile
        node for it — this endpoint never acts as a general file
        reader — and only from inside the allowed roots, resolved
        through the same scandir discipline as document serving.

        The response labels what was served via ``source`` (``file``
        for full on-disk content) and reports the 1-based line range
        the content covers, so the viewer can number lines truthfully
        for any future excerpt source.
        """
        if not path or "\x00" in path:
            raise HTTPException(status_code=400, detail="path required")
        if _is_code_file_traversal(path):
            raise HTTPException(
                status_code=403, detail="Path traversal is forbidden"
            )
        try:
            indexed = await asyncio.to_thread(
                indexed_file, path, tenant_id=tenant_id
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to look up code file"
            ) from e
        if indexed is None:
            raise HTTPException(status_code=404, detail="Code file not indexed")
        resolved = await asyncio.to_thread(_resolve_code_file_on_disk, path)
        if resolved is None:
            raise HTTPException(
                status_code=404, detail="Code file not found on server"
            )
        content = await asyncio.to_thread(_read_code_file_text, resolved)
        lines = content.splitlines()
        return {
            "path": path,
            "source": "file",
            "language": indexed.get("language"),
            "content": content,
            "start_line": 1,
            "end_line": len(lines),
            "line_count": len(lines),
        }

    @app_router.post("/api/v1/vuln/sync")
    async def sync_vuln(tenant_id: str = Depends(get_tenant_id)):
        """Fetch the latest NVD + CISA KEV data into the graph."""
        try:
            counts = await asyncio.to_thread(_sync_vuln_intel, tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to sync vulnerability intel"
            ) from e
        return {"status": "ok", **counts}

    @app_router.post("/api/v1/vuln/report")
    async def get_vuln_report(
        payload: VulnReportRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Join a repo's (or an explicit list of / SBOM) dependencies to CVEs."""
        if payload.dependencies is not None:
            dependencies = payload.dependencies
        elif payload.sbom_json is not None:
            import json
            from backend.ingestion.dependencies import parse_sbom_json_text

            dependencies = parse_sbom_json_text(
                json.dumps(payload.sbom_json), source_file="sbom.json"
            )
        elif payload.repo_path:
            resolved = _validate_repo_path(payload.repo_path)
            dependencies = await asyncio.to_thread(
                extract_dependencies_from_repo, resolved
            )
        else:
            raise HTTPException(
                status_code=400,
                detail="Provide repo_path, dependencies, or sbom_json",
            )
        try:
            vr_kwargs: dict = {"tenant_id": tenant_id}
            if payload.include_reachability:
                vr_kwargs["include_reachability"] = True
            if payload.repo is not None:
                vr_kwargs["repo"] = payload.repo
            report = await asyncio.to_thread(
                vuln_report,
                dependencies,
                **vr_kwargs,
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to build vulnerability report"
            ) from e
        if payload.live_osv and not report.get("findings"):
            try:
                return await asyncio.to_thread(
                    _live_osv_report,
                    dependencies,
                    tenant_id,
                    payload.include_reachability,
                    payload.repo,
                )
            except Exception as e:
                # Live fallback is optional: a failed OSV lookup
                # returns the (empty) graph report, not a 500.
                logger.warning("Live OSV fallback failed: %s", e)
                sentry_sdk.capture_exception(e)
        return report

    @app_router.post("/api/v1/vuln/sarif")
    async def ingest_sarif(
        payload: SarifIngestRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Ingest SARIF 2.1.0 SAST findings into Neo4j and Qdrant."""
        from backend.ingestion.sarif import parse_sarif_payload, write_sarif_findings

        def _ingest() -> dict:
            findings = parse_sarif_payload(payload.sarif)
            qdrant_client = None
            try:
                from backend.config import get_config
                from backend.storage.qdrant_client import QdrantStorageClient

                qdrant_client = QdrantStorageClient.from_config(get_config())
            except Exception as exc:
                logger.warning("Qdrant unavailable during SARIF ingest: %s", exc)
            return write_sarif_findings(
                _default_neo4j_client(),
                findings,
                tenant_id=tenant_id,
                qdrant_client=qdrant_client,
            )

        try:
            counts = await asyncio.to_thread(_ingest)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to ingest SARIF findings"
            ) from e
        return {"status": "ok", "tenant_id": tenant_id, **counts}

    @app_router.post("/api/v1/vuln/recon")
    async def ingest_recon(
        payload: ReconIngestRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Ingest Nuclei, Nmap XML, Burp XML, or Caido recon/DAST findings."""
        from backend.ingestion.recon import parse_recon_output, write_recon_findings

        def _ingest() -> dict:
            findings = parse_recon_output(payload.nuclei)
            qdrant_client = None
            try:
                from backend.config import get_config
                from backend.storage.qdrant_client import QdrantStorageClient

                qdrant_client = QdrantStorageClient.from_config(get_config())
            except Exception as exc:
                logger.warning("Qdrant unavailable during recon ingest: %s", exc)
            return write_recon_findings(
                _default_neo4j_client(),
                findings,
                tenant_id=tenant_id,
                qdrant_client=qdrant_client,
            )

        try:
            counts = await asyncio.to_thread(_ingest)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to ingest recon findings"
            ) from e
        return {"status": "ok", "tenant_id": tenant_id, **counts}

    @app_router.post("/api/v1/vuln/attack/sync")
    async def sync_attack_intel(
        payload: AttackSyncRequest | None = None,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Ingest MITRE ATT&CK (STIX 2.1) techniques, tactics, and mitigations."""
        from backend.ingestion.attack_intel import (
            fetch_attack_stix,
            parse_attack_stix_payload,
            write_attack_intel,
        )

        def _sync() -> dict:
            bundle = (
                payload.stix_json
                if payload is not None and payload.stix_json is not None
                else fetch_attack_stix()
            )
            parsed = parse_attack_stix_payload(bundle)
            qdrant_client = None
            try:
                from backend.config import get_config
                from backend.storage.qdrant_client import QdrantStorageClient

                qdrant_client = QdrantStorageClient.from_config(get_config())
            except Exception as exc:
                logger.warning("Qdrant unavailable during ATT&CK sync: %s", exc)
            return write_attack_intel(
                _default_neo4j_client(),
                parsed,
                tenant_id=tenant_id,
                qdrant_client=qdrant_client,
            )

        try:
            counts = await asyncio.to_thread(_sync)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to sync MITRE ATT&CK intel"
            ) from e
        return {"status": "ok", "tenant_id": tenant_id, **counts}

    @app_router.post("/api/v1/vuln/alerts")
    async def ingest_alerts(
        payload: AlertIngestRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Ingest SOC/SIEM security alerts & IOCs into Neo4j and Qdrant."""
        from backend.ingestion.alerts import parse_alert_payload, write_security_alerts

        def _ingest() -> dict:
            alerts = parse_alert_payload(payload.alerts)
            qdrant_client = None
            try:
                from backend.config import get_config
                from backend.storage.qdrant_client import QdrantStorageClient

                qdrant_client = QdrantStorageClient.from_config(get_config())
            except Exception as exc:
                logger.warning("Qdrant unavailable during alert ingest: %s", exc)
            return write_security_alerts(
                _default_neo4j_client(),
                alerts,
                tenant_id=tenant_id,
                qdrant_client=qdrant_client,
            )

        try:
            counts = await asyncio.to_thread(_ingest)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to ingest security alerts"
            ) from e
        return {"status": "ok", "tenant_id": tenant_id, **counts}
