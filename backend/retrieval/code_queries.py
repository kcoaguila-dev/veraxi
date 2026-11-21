"""Repo X-Ray query layer over the structural code graph.

Queries run against an injectable :class:`CodeGraphClient` protocol so
tests can substitute an in-memory fake; the production implementation
is :class:`Neo4jCodeGraphClient`, which adapts the existing Neo4j
storage client and issues parameterized Cypher only (labels are
interpolated solely from the fixed code-node label list).

Traversal logic (impact analysis) lives here, not in Cypher: the
client exposes one-hop reverse-neighbour lookups and this module walks
them breadth-first up to ``max_depth``. That keeps the traversal
identical against the real adapter and any test fake.
"""

from __future__ import annotations

import logging
import subprocess
from typing import Any, Protocol, runtime_checkable

logger = logging.getLogger(__name__)

CODE_NODE_LABELS = ("CodeFile", "CodeModule", "Class", "Function")
IMPACT_EDGE_TYPES = ("CALLS", "IMPORTS")
MAX_IMPACT_DEPTH = 10


def code_source_url(
    path: Any, line: Any = None, end_line: Any = None
) -> str | None:
    """Build the citable ``file://`` URL for one code hit.

    This is the single place code-hit citation URLs are formatted, so
    every consumer (chat tools, REST routes, CLI) cites identically.
    The anchor uses only line data the graph actually stored: a full
    ``#L<start>-L<end>`` range when an end line is known, a bare
    ``#L<start>`` when only the declaration line is known, and no
    anchor at all when no line is known. Lines are never invented —
    a hit without a path yields ``None`` (no citation target).
    """
    if not isinstance(path, str) or not path.strip():
        return None
    url = f"file://{path.strip()}"
    start = line if isinstance(line, int) and line > 0 else None
    if start is None:
        return url
    end = end_line if isinstance(end_line, int) and end_line > start else None
    if end is not None:
        return f"{url}#L{start}-L{end}"
    return f"{url}#L{start}"


def _attach_url(row: dict[str, Any]) -> dict[str, Any]:
    """Add the citable ``url`` to one code-hit row, in place."""
    url = code_source_url(row.get("path"), row.get("line"), row.get("end_line"))
    if url is not None:
        row["url"] = url
    return row


@runtime_checkable
class CodeGraphClient(Protocol):
    """Injectable graph-client interface for code-graph queries."""

    def find_symbols(
        self,
        tenant_id: str,
        *,
        qualified_name: str | None = None,
        name: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return code nodes matching a qualified name or a simple name."""
        ...

    def find_file(
        self, tenant_id: str, path: str
    ) -> dict[str, Any] | None:
        """Return the CodeFile row for ``path`` under ``tenant_id``.

        The row carries ``path`` and ``language``. ``None`` means the
        tenant's code graph holds no file at that path — the tenant
        scoping check for serving code file content.
        """
        ...

    def incoming_edges(
        self, tenant_id: str, target_qns: list[str]
    ) -> list[dict[str, Any]]:
        """Return CALLS/IMPORTS edges pointing INTO any of ``target_qns``.

        Each row: ``source_qn``, ``source_name``, ``source_label``,
        ``source_path``, ``source_line``, ``source_end_line``,
        ``edge_type`` and ``target_qn``. The line fields mirror the
        source node's stored ``line``/``end_line`` and may be missing
        on clients backed by graphs ingested before they existed.
        """
        ...

    def node_counts(
        self, tenant_id: str, path_prefix: str | None = None
    ) -> dict[str, int]:
        """Return code-node counts keyed by label."""
        ...

    def edge_counts(
        self, tenant_id: str, path_prefix: str | None = None
    ) -> dict[str, int]:
        """Return code-edge counts keyed by relationship type."""
        ...

    def top_connected(
        self, tenant_id: str, path_prefix: str | None = None, limit: int = 10
    ) -> list[dict[str, Any]]:
        """Return the most-connected code nodes for the tenant."""
        ...

    def index_meta(self, tenant_id: str) -> dict[str, Any] | None:
        """Return the tenant's latest index-provenance stamp, or None.

        The stamp (written at ingestion time by
        ``backend.ingestion.code_graph.write_index_meta``) carries
        ``repo_key``, ``repo_root``, ``source_commit``, ``indexed_at``
        and ``kind``. None means the graph predates index metadata —
        provenance is unknown, not zero.
        """
        ...


class Neo4jCodeGraphClient:
    """Production :class:`CodeGraphClient` over ``Neo4jStorageClient``.

    All user input travels as query parameters; the only interpolated
    values are the fixed label list above and validated integers.
    """

    def __init__(self, neo4j_client: Any = None) -> None:
        if neo4j_client is None:
            from backend.config import get_config
            from backend.storage.neo4j_client import Neo4jStorageClient

            neo4j_client = Neo4jStorageClient.from_config(get_config())
        self._client = neo4j_client

    def _read(self, query: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        return self._client.execute_read(query, params)

    def find_symbols(
        self,
        tenant_id: str,
        *,
        qualified_name: str | None = None,
        name: str | None = None,
    ) -> list[dict[str, Any]]:
        if qualified_name is not None:
            where = "n.qualified_name = $qualified_name"
            params: dict[str, Any] = {
                "tenant_id": tenant_id,
                "qualified_name": qualified_name,
            }
        else:
            where = "n.name = $name"
            params = {"tenant_id": tenant_id, "name": name}
        query = f"""
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
          AND {where}
        RETURN labels(n)[0] AS label, n.name AS name,
               n.qualified_name AS qualified_name, n.path AS path,
               n.line AS line, n.end_line AS end_line, n.language AS language,
               coalesce(n.resolved, true) AS resolved
        ORDER BY qualified_name
        """
        return self._read(query, params)

    def find_file(
        self, tenant_id: str, path: str
    ) -> dict[str, Any] | None:
        query = """
        MATCH (n:CodeFile)
        WHERE n.tenant_id = $tenant_id AND n.path = $path
        RETURN n.path AS path, n.language AS language
        LIMIT 1
        """
        rows = self._read(query, {"tenant_id": tenant_id, "path": path})
        return rows[0] if rows else None

    def incoming_edges(
        self, tenant_id: str, target_qns: list[str]
    ) -> list[dict[str, Any]]:
        if not target_qns:
            return []
        query = """
        MATCH (source)-[r]->(target)
        WHERE source.tenant_id = $tenant_id
          AND target.tenant_id = $tenant_id
          AND type(r) IN $edge_types
          AND target.qualified_name IN $target_qns
        RETURN source.qualified_name AS source_qn, source.name AS source_name,
               labels(source)[0] AS source_label, source.path AS source_path,
               source.line AS source_line, source.end_line AS source_end_line,
               type(r) AS edge_type, target.qualified_name AS target_qn
        """
        return self._read(
            query,
            {
                "tenant_id": tenant_id,
                "edge_types": list(IMPACT_EDGE_TYPES),
                "target_qns": list(target_qns),
            },
        )

    def node_counts(
        self, tenant_id: str, path_prefix: str | None = None
    ) -> dict[str, int]:
        query = """
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
          AND ($path_prefix IS NULL OR n.path STARTS WITH $path_prefix)
        RETURN labels(n)[0] AS label, count(n) AS count
        """
        rows = self._read(
            query, {"tenant_id": tenant_id, "path_prefix": path_prefix}
        )
        return {row["label"]: int(row["count"]) for row in rows if row.get("label")}

    def edge_counts(
        self, tenant_id: str, path_prefix: str | None = None
    ) -> dict[str, int]:
        query = """
        MATCH (a)-[r]->(b)
        WHERE a.tenant_id = $tenant_id
          AND b.tenant_id = $tenant_id
          AND type(r) IN ['IMPORTS', 'CALLS', 'DEFINES', 'INHERITS']
          AND ($path_prefix IS NULL OR a.path STARTS WITH $path_prefix)
        RETURN type(r) AS edge_type, count(r) AS count
        """
        rows = self._read(
            query, {"tenant_id": tenant_id, "path_prefix": path_prefix}
        )
        return {
            row["edge_type"]: int(row["count"])
            for row in rows
            if row.get("edge_type")
        }

    def top_connected(
        self, tenant_id: str, path_prefix: str | None = None, limit: int = 10
    ) -> list[dict[str, Any]]:
        limit = min(max(1, int(limit)), 100)
        query = f"""
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
          AND ($path_prefix IS NULL OR n.path STARTS WITH $path_prefix)
        OPTIONAL MATCH (n)-[r]-()
        WHERE r.tenant_id = $tenant_id
        RETURN n.qualified_name AS qualified_name, n.name AS name,
               labels(n)[0] AS label, n.path AS path,
               count(r) AS connections
        ORDER BY connections DESC, qualified_name ASC
        LIMIT {limit}
        """
        return self._read(
            query, {"tenant_id": tenant_id, "path_prefix": path_prefix}
        )

    def index_meta(self, tenant_id: str) -> dict[str, Any] | None:
        query = """
        MATCH (m:CodeIndexMeta)
        WHERE m.tenant_id = $tenant_id
        RETURN m.repo_key AS repo_key, m.repo_root AS repo_root,
               m.source_commit AS source_commit, m.indexed_at AS indexed_at,
               m.kind AS kind
        ORDER BY m.indexed_at DESC
        LIMIT 1
        """
        rows = self._read(query, {"tenant_id": tenant_id})
        return rows[0] if rows else None


def _default_client(client: CodeGraphClient | None) -> CodeGraphClient:
    return client if client is not None else Neo4jCodeGraphClient()


def _git_head_sha(root: str) -> str | None:
    """Current HEAD SHA of the checkout at ``root``, or None.

    A five-line stdlib probe kept local to the retrieval layer (the
    ingestion layer owns the full git machinery). Any failure — no
    git binary, not a checkout, missing directory — yields None so
    callers omit staleness rather than guess it.
    """
    try:
        result = subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def _freshness_block(client: CodeGraphClient, tenant_id: str) -> dict[str, Any]:
    """Index-provenance disclosure attached to every query result.

    Always present, additive: ``indexed_commit`` / ``indexed_at``
    mirror the ingestion stamp (None when the graph predates index
    metadata or the client keeps no stamp). ``current_commit`` and
    ``stale`` are added only when the stamped repo root is a checkout
    on this machine whose HEAD can be read — when HEAD cannot be
    checked, ``stale`` is omitted rather than guessed.
    """
    block: dict[str, Any] = {"indexed_commit": None, "indexed_at": None}
    meta_fn = getattr(client, "index_meta", None)
    if not callable(meta_fn):
        return block
    try:
        meta = meta_fn(tenant_id)
    except Exception:
        logger.warning("index_meta lookup failed for tenant %s", tenant_id, exc_info=True)
        return block
    if not meta:
        return block
    block["indexed_commit"] = meta.get("source_commit")
    block["indexed_at"] = meta.get("indexed_at")
    root = meta.get("repo_root")
    indexed = meta.get("source_commit")
    if root and indexed:
        head = _git_head_sha(str(root))
        if head is not None:
            block["current_commit"] = head
            block["stale"] = head != indexed
    return block


def symbol_lookup(
    name: str,
    tenant_id: str = "default",
    client: CodeGraphClient | None = None,
) -> dict[str, Any]:
    """Look up a code symbol by qualified name, then by simple name.

    Exact qualified-name matches win: simple-name matches are only
    consulted when no qualified name matches, so a fully-qualified
    query never returns same-named symbols from other modules.
    """
    graph_client = _default_client(client)
    freshness = _freshness_block(graph_client, tenant_id)
    query = (name or "").strip()
    if not query:
        return {"query": query, "match_type": None, "matches": [], "freshness": freshness}
    matches = graph_client.find_symbols(tenant_id, qualified_name=query)
    if matches:
        return {
            "query": query,
            "match_type": "qualified_name",
            "matches": [_attach_url(match) for match in matches],
            "freshness": freshness,
        }
    matches = graph_client.find_symbols(tenant_id, name=query)
    return {
        "query": query,
        "match_type": "name" if matches else None,
        "matches": [_attach_url(match) for match in matches],
        "freshness": freshness,
    }


def indexed_file(
    path: str,
    tenant_id: str = "default",
    client: CodeGraphClient | None = None,
) -> dict[str, Any] | None:
    """Return the indexed CodeFile row for ``path`` under ``tenant_id``.

    This is the tenant-scoping check for serving code file content:
    a repo-relative path is servable only when the tenant's code
    graph holds a CodeFile node for it. Returns ``None`` when the
    tenant has no such file indexed (or the path is blank).
    """
    graph_client = _default_client(client)
    query = (path or "").strip()
    if not query:
        return None
    return graph_client.find_file(tenant_id, query)


def impact_analysis(
    symbol: str,
    tenant_id: str = "default",
    max_depth: int = 3,
    client: CodeGraphClient | None = None,
) -> dict[str, Any]:
    """Reverse-dependency impact: who CALLS/IMPORTS ``symbol``, transitively.

    Resolves ``symbol`` exactly (qualified name first, then simple
    name), then breadth-first walks incoming CALLS/IMPORTS edges from
    the defining node(s). A caller at depth 1 calls/imports the symbol
    directly; deeper entries reach it through a chain of callers.
    """
    graph_client = _default_client(client)
    freshness = _freshness_block(graph_client, tenant_id)
    depth_limit = min(max(1, int(max_depth)), MAX_IMPACT_DEPTH)
    lookup = symbol_lookup(symbol, tenant_id=tenant_id, client=graph_client)
    roots = lookup["matches"]
    if not roots:
        return {
            "symbol": symbol,
            "found": False,
            "roots": [],
            "max_depth": depth_limit,
            "impacted": [],
            "freshness": freshness,
        }
    root_qns = {root["qualified_name"] for root in roots}
    seen: set[str] = set(root_qns)
    impacted: list[dict[str, Any]] = []
    frontier = sorted(root_qns)
    for depth in range(1, depth_limit + 1):
        if not frontier:
            break
        next_frontier: list[str] = []
        for row in graph_client.incoming_edges(tenant_id, frontier):
            source_qn = row.get("source_qn")
            if not source_qn or source_qn in seen:
                continue
            seen.add(source_qn)
            next_frontier.append(source_qn)
            entry = {
                "qualified_name": source_qn,
                "name": row.get("source_name"),
                "label": row.get("source_label"),
                "path": row.get("source_path"),
                "line": row.get("source_line"),
                "end_line": row.get("source_end_line"),
                "depth": depth,
                "via_edge": row.get("edge_type"),
                "via_target": row.get("target_qn"),
            }
            url = code_source_url(entry["path"], entry["line"], entry["end_line"])
            if url is not None:
                entry["url"] = url
            impacted.append(entry)
        frontier = sorted(next_frontier)
    impacted.sort(key=lambda item: (item["depth"], item["qualified_name"]))
    return {
        "symbol": symbol,
        "found": True,
        "roots": roots,
        "max_depth": depth_limit,
        "impacted": impacted,
        "freshness": freshness,
    }


def repo_overview(
    tenant_id: str = "default",
    path_prefix: str | None = None,
    client: CodeGraphClient | None = None,
    top_limit: int = 10,
) -> dict[str, Any]:
    """Counts per node/edge type plus the most-connected symbols."""
    graph_client = _default_client(client)
    node_counts = graph_client.node_counts(tenant_id, path_prefix)
    edge_counts = graph_client.edge_counts(tenant_id, path_prefix)
    return {
        "tenant_id": tenant_id,
        "path_prefix": path_prefix,
        "node_counts": node_counts,
        "edge_counts": edge_counts,
        "total_nodes": sum(node_counts.values()),
        "total_edges": sum(edge_counts.values()),
        "freshness": _freshness_block(graph_client, tenant_id),
        # top_connected rows carry a path but no line, so their URLs
        # are plain file:// links without a line anchor.
        "top_connected": [
            _attach_url(row)
            for row in graph_client.top_connected(
                tenant_id, path_prefix, limit=top_limit
            )
        ],
    }


__all__ = [
    "CODE_NODE_LABELS",
    "IMPACT_EDGE_TYPES",
    "MAX_IMPACT_DEPTH",
    "CodeGraphClient",
    "Neo4jCodeGraphClient",
    "code_source_url",
    "impact_analysis",
    "repo_overview",
    "symbol_lookup",
]
