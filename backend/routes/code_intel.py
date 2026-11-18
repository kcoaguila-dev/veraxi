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
import logging
import os

import sentry_sdk
from fastapi import Depends, HTTPException
from pydantic import BaseModel

from backend.ingestion.code_graph import (
    MAX_INGEST_EDGES,
    MAX_INGEST_NODES,
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
from backend.retrieval.code_queries import impact_analysis, repo_overview, symbol_lookup
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


class CodeIngestRequest(BaseModel):
    repo_path: str


class CodeIngestGraphRequest(BaseModel):
    repo_name: str
    nodes: list[dict] = []
    edges: list[dict] = []


class VulnReportRequest(BaseModel):
    repo_path: str | None = None
    dependencies: list[dict] | None = None
    sbom_json: dict | None = None
    include_reachability: bool = False
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

        attach_code_reachability(report["findings"], tenant_id=tenant_id)
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
    )


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

    @app_router.get("/api/v1/code/overview")
    async def get_code_overview(tenant_id: str = Depends(get_tenant_id)):
        """Node/edge counts plus the most-connected symbols."""
        try:
            return await asyncio.to_thread(repo_overview, tenant_id=tenant_id)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to load code overview"
            ) from e

    @app_router.get("/api/v1/code/symbol")
    async def get_code_symbol(
        name: str = "", tenant_id: str = Depends(get_tenant_id)
    ):
        """Look up a code symbol by qualified or simple name."""
        try:
            return await asyncio.to_thread(
                symbol_lookup, name, tenant_id=tenant_id
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
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Reverse-dependency impact tree for a symbol."""
        try:
            return await asyncio.to_thread(
                impact_analysis, symbol, tenant_id=tenant_id, max_depth=max_depth
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(
                status_code=500, detail="Failed to run impact analysis"
            ) from e

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
        """Ingest Nuclei JSON/JSONL recon/DAST findings into Neo4j and Qdrant."""
        from backend.ingestion.recon import parse_nuclei_output, write_recon_findings

        def _ingest() -> dict:
            findings = parse_nuclei_output(payload.nuclei)
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
