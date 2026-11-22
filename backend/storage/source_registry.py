"""Tenant source inventory and ADR-0002 dual-store cleanup helpers.

Lives in ``backend/storage/`` so both ``routes/`` and ``admin`` endpoints
can query and purge sources without crossing retrieval or mcp_server layers.
"""

from __future__ import annotations

import logging
import os
from datetime import UTC, datetime, timedelta
from typing import Any

import sentry_sdk

logger = logging.getLogger(__name__)


def get_stale_source_days() -> int:
    """Return configured staleness threshold in days (default 14)."""
    raw = os.environ.get("STALE_SOURCE_DAYS", "14")
    try:
        parsed = int(raw)
        return parsed if parsed > 0 else 14
    except ValueError:
        return 14


def _format_relative_age(iso_ts: str | None, stale_days: int) -> tuple[str, bool]:
    """Convert an ISO-8601 timestamp into a human-readable age and staleness flag."""
    if not iso_ts:
        return "Indexed", False
    try:
        dt = datetime.fromisoformat(str(iso_ts).replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=UTC)
        now = datetime.now(UTC)
        delta = max(now - dt, timedelta(0))
        is_stale = delta >= timedelta(days=stale_days)
        total_seconds = int(delta.total_seconds())
        if total_seconds < 60:
            return "Just now", is_stale
        if total_seconds < 3600:
            return f"{total_seconds // 60}m ago", is_stale
        if total_seconds < 86400:
            return f"{total_seconds // 3600}h ago", is_stale
        return f"{delta.days}d ago", is_stale
    except Exception:
        return "Indexed", False


def _scroll_tenant_qdrant_sources(
    qdrant: Any, collection_name: str, tenant_id: str
) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    """Aggregate Qdrant chunk counts and point-to-source mapping for one tenant."""
    from qdrant_client.http import models

    sources: dict[str, dict[str, Any]] = {}
    point_to_source: dict[str, str] = {}
    tenant_filter = models.Filter(
        must=[
            models.FieldCondition(
                key="tenant_id", match=models.MatchValue(value=tenant_id)
            )
        ]
    )

    offset = None
    while True:
        records, next_offset = qdrant.client.scroll(
            collection_name=collection_name,
            scroll_filter=tenant_filter,
            limit=500,
            offset=offset,
            with_payload=True,
            with_vectors=False,
        )
        for point in records:
            payload = getattr(point, "payload", None) or {}
            src = str(payload.get("source") or "unknown")
            src_type = str(payload.get("source_type") or "Document")
            ingested_at = payload.get("ingested_at")
            entry = sources.setdefault(
                src,
                {
                    "chunks": 0,
                    "source_type": src_type,
                    "ingested_at": ingested_at,
                },
            )
            entry["chunks"] += 1
            if ingested_at and (
                not entry["ingested_at"] or str(ingested_at) > str(entry["ingested_at"])
            ):
                entry["ingested_at"] = ingested_at
            point_to_source[str(point.id)] = src

        if next_offset is None or not records:
            break
        offset = next_offset

    return sources, point_to_source


def _infer_doc_type(source: str, source_type: str) -> str:
    lower = source.lower()
    if lower.startswith(("http://", "https://")):
        return "URL"
    if lower.endswith(".pdf"):
        return "PDF"
    if lower.endswith((".md", ".markdown")):
        return "Markdown"
    if lower.endswith(".csv"):
        return "CSV"
    if lower.endswith((".doc", ".docx")):
        return "DOCX"
    if source_type and source_type != "document":
        return source_type.upper()
    return "Document"


def list_tenant_sources(
    tenant_id: str,
    neo4j: Any,
    qdrant: Any,
    collection_name: str,
    stale_days: int | None = None,
) -> list[dict[str, Any]]:
    """Return unified inventory of indexed code repos, documents, and vuln catalogs."""
    effective_stale_days = (
        stale_days if stale_days is not None else get_stale_source_days()
    )
    results: list[dict[str, Any]] = []

    # 1. Code AST Repositories
    try:
        metas = neo4j.execute_read(
            """
            MATCH (m:CodeIndexMeta {tenant_id: $tenant_id})
            RETURN m.repo_key AS repo_key,
                   m.repo_root AS repo_root,
                   m.source_commit AS source_commit,
                   m.indexed_at AS indexed_at
            ORDER BY m.indexed_at DESC
            """,
            {"tenant_id": tenant_id},
        )
        repo_stats_rows = neo4j.execute_read(
            """
            MATCH (n {tenant_id: $tenant_id})
            WHERE n.repo_key IS NOT NULL AND NOT n:CodeIndexMeta
            RETURN n.repo_key AS repo_key,
                   sum(CASE WHEN n:File OR n:CodeFile THEN 1 ELSE 0 END) AS files,
                   sum(CASE WHEN NOT (n:File OR n:CodeFile) THEN 1 ELSE 0 END) AS symbols
            """,
            {"tenant_id": tenant_id},
        )
        repo_stats = {
            row["repo_key"]: row for row in repo_stats_rows if row.get("repo_key")
        }
        for meta in metas:
            rk = meta.get("repo_key")
            if not rk:
                continue
            counts = repo_stats.get(rk, {})
            files = int(counts.get("files") or 0)
            symbols = int(counts.get("symbols") or 0)
            age_label, is_stale = _format_relative_age(
                meta.get("indexed_at"), effective_stale_days
            )
            results.append(
                {
                    "id": str(rk),
                    "name": str(rk),
                    "subtitle": str(meta.get("repo_root") or rk),
                    "type": "Code AST",
                    "category": "repo",
                    "counts": f"{files} files · {symbols} nodes",
                    "last_synced": age_label,
                    "is_stale": is_stale,
                    "repo_root": meta.get("repo_root"),
                    "indexed_at": meta.get("indexed_at"),
                }
            )
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.warning("Failed listing indexed code repos for %s: %s", tenant_id, exc)

    # 2. Document Sources (Qdrant chunks <-> Neo4j nodes via qdrant_point_ids)
    try:
        qdrant_sources, point_to_source = _scroll_tenant_qdrant_sources(
            qdrant, collection_name, tenant_id
        )
        node_counts_by_source: dict[str, int] = {}
        if qdrant_sources:
            neo_rows = neo4j.execute_read(
                """
                MATCH (n {tenant_id: $tenant_id})
                WHERE NOT n:CodeIndexMeta
                  AND NOT n:CVE AND NOT n:CWE AND NOT n:Package
                  AND n.repo_key IS NULL
                RETURN n.source AS source, n.qdrant_point_ids AS pids
                """,
                {"tenant_id": tenant_id},
            )
            for row in neo_rows:
                matched_sources: set[str] = set()
                if row.get("source"):
                    matched_sources.add(str(row["source"]))
                for pid in row.get("pids") or []:
                    src = point_to_source.get(str(pid))
                    if src:
                        matched_sources.add(src)
                for src in matched_sources:
                    node_counts_by_source[src] = node_counts_by_source.get(src, 0) + 1

        for src, info in sorted(qdrant_sources.items()):
            chunks = info["chunks"]
            nodes = node_counts_by_source.get(src, 0)
            age_label, is_stale = _format_relative_age(
                info.get("ingested_at"), effective_stale_days
            )
            doc_type = _infer_doc_type(src, info.get("source_type", ""))
            subtitle = "URL Source" if doc_type == "URL" else "Ingested Document"
            results.append(
                {
                    "id": src,
                    "name": src,
                    "subtitle": subtitle,
                    "type": doc_type,
                    "category": "doc",
                    "counts": f"{chunks} chunks · {nodes} nodes",
                    "last_synced": age_label,
                    "is_stale": is_stale,
                    "ingested_at": info.get("ingested_at"),
                }
            )
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.warning("Failed listing document sources for %s: %s", tenant_id, exc)

    # 3. Vulnerability Intelligence Catalog
    try:
        vuln_rows = neo4j.execute_read(
            """
            MATCH (c:CVE {tenant_id: $tenant_id})
            RETURN count(c) AS cve_count,
                   sum(CASE WHEN c.kev = true THEN 1 ELSE 0 END) AS kev_count,
                   max(c.last_modified) AS last_modified
            """,
            {"tenant_id": tenant_id},
        )
        if vuln_rows and int(vuln_rows[0].get("cve_count") or 0) > 0:
            cve_count = int(vuln_rows[0]["cve_count"])
            kev_count = int(vuln_rows[0].get("kev_count") or 0)
            results.append(
                {
                    "id": "nvd_kev_catalog",
                    "name": "NVD + CISA KEV Catalog",
                    "subtitle": "Public Vulnerability Feed",
                    "type": "Vuln Graph",
                    "category": "feed",
                    "counts": f"{cve_count} CVE · {kev_count} KEV",
                    "last_synced": "Synced",
                    "is_stale": False,
                }
            )
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.warning("Failed listing vuln catalog for %s: %s", tenant_id, exc)

    return results


def _delete_qdrant_by_field(
    qdrant: Any,
    collection_name: str,
    tenant_id: str,
    field: str,
    value: str,
) -> tuple[int, list[str]]:
    """Collect matching Qdrant point IDs for a tenant source and delete them."""
    from qdrant_client.http import models

    src_filter = models.Filter(
        must=[
            models.FieldCondition(
                key="tenant_id", match=models.MatchValue(value=tenant_id)
            ),
            models.FieldCondition(key=field, match=models.MatchValue(value=value)),
        ]
    )
    point_ids: list[str] = []
    offset = None
    while True:
        records, next_offset = qdrant.client.scroll(
            collection_name=collection_name,
            scroll_filter=src_filter,
            limit=500,
            offset=offset,
            with_payload=False,
            with_vectors=False,
        )
        point_ids.extend(str(r.id) for r in records)
        if next_offset is None or not records:
            break
        offset = next_offset

    if point_ids:
        qdrant.client.delete(
            collection_name=collection_name,
            points_selector=models.FilterSelector(filter=src_filter),
        )
    return len(point_ids), point_ids


def delete_tenant_source(
    tenant_id: str,
    source_id: str,
    category: str,
    neo4j: Any,
    qdrant: Any,
    collection_name: str,
) -> dict[str, int]:
    """Delete a tenant source from both Neo4j and Qdrant (ADR-0002 compliant)."""
    deleted_nodes = 0
    deleted_vectors = 0

    if category == "repo":
        deleted_vectors, _ = _delete_qdrant_by_field(
            qdrant, collection_name, tenant_id, "repo_key", source_id
        )
        rows = neo4j.execute_write(
            """
            MATCH (n {tenant_id: $tenant_id, repo_key: $repo_key})
            WITH collect(n) AS nodes, count(n) AS total
            FOREACH (node IN nodes | DETACH DELETE node)
            RETURN total AS deleted
            """,
            {"tenant_id": tenant_id, "repo_key": source_id},
        )
        deleted_nodes = int(rows[0].get("deleted") or 0) if rows else 0
        return {"deleted_nodes": deleted_nodes, "deleted_vectors": deleted_vectors}

    if category == "feed":
        rows = neo4j.execute_write(
            """
            MATCH (n {tenant_id: $tenant_id})
            WHERE n:CVE OR n:CWE OR n:Package
            WITH collect(n) AS nodes, count(n) AS total
            FOREACH (node IN nodes | DETACH DELETE node)
            RETURN total AS deleted
            """,
            {"tenant_id": tenant_id},
        )
        deleted_nodes = int(rows[0].get("deleted") or 0) if rows else 0
        return {"deleted_nodes": deleted_nodes, "deleted_vectors": 0}

    # Document source cleanup: purge Qdrant points first, then unlink/delete Neo4j nodes.
    deleted_vectors, point_ids = _delete_qdrant_by_field(
        qdrant, collection_name, tenant_id, "source", source_id
    )
    neo4j.execute_write(
        """
        MATCH ()-[r {tenant_id: $tenant_id, source: $source_id}]-()
        DELETE r
        """,
        {"tenant_id": tenant_id, "source_id": source_id},
    )
    rows = neo4j.execute_write(
        """
        MATCH (n {tenant_id: $tenant_id})
        WHERE n.source = $source_id
           OR (size($point_ids) > 0
               AND any(pid IN coalesce(n.qdrant_point_ids, []) WHERE pid IN $point_ids)
               AND size([pid IN coalesce(n.qdrant_point_ids, []) WHERE NOT pid IN $point_ids]) = 0)
        WITH collect(n) AS nodes, count(n) AS total
        FOREACH (node IN nodes | DETACH DELETE node)
        RETURN total AS deleted
        """,
        {"tenant_id": tenant_id, "source_id": source_id, "point_ids": point_ids},
    )
    deleted_nodes = int(rows[0].get("deleted") or 0) if rows else 0
    if point_ids:
        neo4j.execute_write(
            """
            MATCH (n {tenant_id: $tenant_id})
            WHERE any(pid IN coalesce(n.qdrant_point_ids, []) WHERE pid IN $point_ids)
            SET n.qdrant_point_ids = [pid IN n.qdrant_point_ids WHERE NOT pid IN $point_ids]
            """,
            {"tenant_id": tenant_id, "point_ids": point_ids},
        )
    return {"deleted_nodes": deleted_nodes, "deleted_vectors": deleted_vectors}
