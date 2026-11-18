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
from typing import Any, Protocol, runtime_checkable

logger = logging.getLogger(__name__)

CODE_NODE_LABELS = ("CodeFile", "CodeModule", "Class", "Function")
IMPACT_EDGE_TYPES = ("CALLS", "IMPORTS")
MAX_IMPACT_DEPTH = 10


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

    def incoming_edges(
        self, tenant_id: str, target_qns: list[str]
    ) -> list[dict[str, Any]]:
        """Return CALLS/IMPORTS edges pointing INTO any of ``target_qns``.

        Each row: ``source_qn``, ``source_name``, ``source_label``,
        ``source_path``, ``edge_type`` and ``target_qn``.
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
               n.line AS line, n.language AS language,
               coalesce(n.resolved, true) AS resolved
        ORDER BY qualified_name
        """
        return self._read(query, params)

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


def _default_client(client: CodeGraphClient | None) -> CodeGraphClient:
    return client if client is not None else Neo4jCodeGraphClient()


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
    query = (name or "").strip()
    if not query:
        return {"query": query, "match_type": None, "matches": []}
    matches = graph_client.find_symbols(tenant_id, qualified_name=query)
    if matches:
        return {"query": query, "match_type": "qualified_name", "matches": matches}
    matches = graph_client.find_symbols(tenant_id, name=query)
    return {
        "query": query,
        "match_type": "name" if matches else None,
        "matches": matches,
    }


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
            impacted.append(
                {
                    "qualified_name": source_qn,
                    "name": row.get("source_name"),
                    "label": row.get("source_label"),
                    "path": row.get("source_path"),
                    "depth": depth,
                    "via_edge": row.get("edge_type"),
                    "via_target": row.get("target_qn"),
                }
            )
        frontier = sorted(next_frontier)
    impacted.sort(key=lambda item: (item["depth"], item["qualified_name"]))
    return {
        "symbol": symbol,
        "found": True,
        "roots": roots,
        "max_depth": depth_limit,
        "impacted": impacted,
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
        "top_connected": graph_client.top_connected(
            tenant_id, path_prefix, limit=top_limit
        ),
    }


__all__ = [
    "CODE_NODE_LABELS",
    "IMPACT_EDGE_TYPES",
    "MAX_IMPACT_DEPTH",
    "CodeGraphClient",
    "Neo4jCodeGraphClient",
    "impact_analysis",
    "repo_overview",
    "symbol_lookup",
]
