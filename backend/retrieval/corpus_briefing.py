"""Corpus Briefing: a deterministic snapshot of a tenant's graph.

Layering choice (documented per the Phase 6 brief): this module lives
in ``retrieval/``, not ``services/``, because its core input —
community detection — already lives in
:mod:`backend.retrieval.graph_analytics` and is consumed today by the
tools layer (``mcp_server/tools/run_analytics.py`` ->
``retrieval.graph_analytics``). Briefing is a read/query concern like
``code_queries`` and ``vuln_queries``: it follows the same injectable
:class:`BriefingGraphClient` protocol pattern, and the MCP tool in
``mcp_server/tools`` is a thin wrapper over it. ``services/`` hosts
write/integration concerns (sync, stores, importers), not graph reads.

Determinism: there are NO LLM calls anywhere in this module. Every
section is computed from graph counts, the existing Louvain/fallback
community detection, node degrees, relationship timestamps and a
fixed functional-relation heuristic (below).

Newest entities — honest proxy: graph *nodes* carry no creation
timestamp. ``Neo4jStorageClient.upsert_entity`` sets only ``id``,
``tenant_id``, ``name``, ``aliases`` and ``qdrant_point_ids`` on
create; no ``created_at``/``first_seen`` property exists on nodes
(checked in ``storage/neo4j_client.py`` and
``ingestion/graph_write.py``). *Relationships*, however, do carry
``first_seen_at`` (set by ``upsert_relationship``). The newest-entity
list therefore reports, per entity, the earliest ``first_seen_at``
among its relationships as ``first_seen`` — the first time the graph
recorded a relationship involving that entity. That is a proxy for
first appearance, not a node creation time, and entities with no
timestamped relationship are omitted rather than assigned an
invented date.

Contradiction flags — heuristic, not truth: the extraction schema
has no functional/single-valued relation marker (schemas are dynamic;
see ``ingestion/extract.py`` validation against a caller-supplied
schema). The deterministic rule used here is: flag ``(entity,
relation)`` when ``relation`` is in :data:`FUNCTIONAL_RELATIONS` and
the entity has that relation pointing to 2+ DISTINCT targets. The set
is deliberately small and contains only relation types that appear in
this codebase's extraction schemas and are typically single-valued:
``BORN_IN`` (Person -> Location and ``LIVES_IN``-style multi-valued
relations are excluded), ``HEADQUARTERED_IN`` (Organization ->
Location) and ``LOCATED_IN`` (Location -> Location), all from
``DEFAULT_SCHEMA`` in ``mcp_server/tools/dynamic_web_graph.py``.
Multi-valued relations found in the same schemas (``WORKS_AT`` /
``WORKS_FOR``, ``MEMBER_OF``, ``OPERATES_IN``, ``ACQUIRED``, ...)
are intentionally NOT flagged. A flag means "worth a human look",
never "this is false".
"""

from __future__ import annotations

import logging
from typing import Any, Protocol, runtime_checkable

logger = logging.getLogger(__name__)

FUNCTIONAL_RELATIONS: tuple[str, ...] = (
    "BORN_IN",
    "HEADQUARTERED_IN",
    "LOCATED_IN",
)

CONTRADICTION_RULE = (
    "Flag (entity, relation) when relation is in FUNCTIONAL_RELATIONS "
    f"{list(FUNCTIONAL_RELATIONS)} and the entity has that relation "
    "pointing to 2+ distinct targets. Heuristic, not truth: the "
    "extraction schema marks no relation as functional/single-valued."
)


@runtime_checkable
class BriefingGraphClient(Protocol):
    """Injectable graph-client interface for corpus briefing queries."""

    def communities(
        self, tenant_id: str, min_community_size: int = 1
    ) -> list[dict[str, Any]]:
        """Return community rows: ``community``, ``size``, ``members``."""
        ...

    def corpus_counts(self, tenant_id: str) -> dict[str, Any]:
        """Return ``nodes_by_label`` / ``relationships_by_type`` dicts."""
        ...

    def entity_degrees(
        self, tenant_id: str, names: list[str]
    ) -> list[dict[str, Any]]:
        """Return ``name`` / ``type`` / ``degree`` rows for ``names``."""
        ...

    def newest_entities(
        self, tenant_id: str, limit: int = 10
    ) -> list[dict[str, Any]]:
        """Return ``name`` / ``type`` / ``first_seen`` rows, newest first."""
        ...

    def functional_relation_rows(
        self, tenant_id: str, relation_types: list[str]
    ) -> list[dict[str, Any]]:
        """Return ``entity`` / ``relation`` / ``targets`` rows."""
        ...


class Neo4jBriefingClient:
    """Production :class:`BriefingGraphClient` over ``Neo4jStorageClient``.

    Community detection REUSES
    :func:`backend.retrieval.graph_analytics.get_community_detection`
    (GDS Louvain with the label fallback) — it is not reimplemented
    here. All other queries are parameterized Cypher only; relation
    types travel as a parameter, never interpolated.
    """

    def __init__(self, neo4j_client: Any = None) -> None:
        if neo4j_client is None:
            from backend.config import get_config
            from backend.storage.neo4j_client import Neo4jStorageClient

            neo4j_client = Neo4jStorageClient.from_config(get_config())
        self._client = neo4j_client

    def _read(self, query: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        return self._client.execute_read(query, params)

    def communities(
        self, tenant_id: str, min_community_size: int = 1
    ) -> list[dict[str, Any]]:
        from backend.retrieval.graph_analytics import get_community_detection

        return get_community_detection(
            self._client,
            min_community_size=min_community_size,
            tenant_id=tenant_id,
        )

    def corpus_counts(self, tenant_id: str) -> dict[str, Any]:
        node_rows = self._read(
            """
            MATCH (n {tenant_id: $tenant_id})
            RETURN coalesce(labels(n)[0], 'Entity') AS label, count(n) AS count
            """,
            {"tenant_id": tenant_id},
        )
        rel_rows = self._read(
            """
            MATCH (a {tenant_id: $tenant_id})-[r]->(b {tenant_id: $tenant_id})
            RETURN type(r) AS rel_type, count(r) AS count
            """,
            {"tenant_id": tenant_id},
        )
        return {
            "nodes_by_label": {
                row["label"]: int(row["count"]) for row in node_rows if row.get("label")
            },
            "relationships_by_type": {
                row["rel_type"]: int(row["count"])
                for row in rel_rows
                if row.get("rel_type")
            },
        }

    def entity_degrees(
        self, tenant_id: str, names: list[str]
    ) -> list[dict[str, Any]]:
        if not names:
            return []
        return self._read(
            """
            MATCH (n {tenant_id: $tenant_id})
            WHERE n.name IN $names
            OPTIONAL MATCH (n)-[r]-()
            WHERE r.tenant_id = $tenant_id
            RETURN n.name AS name, coalesce(labels(n)[0], 'Entity') AS type,
                   count(r) AS degree
            """,
            {"tenant_id": tenant_id, "names": list(names)},
        )

    def newest_entities(
        self, tenant_id: str, limit: int = 10
    ) -> list[dict[str, Any]]:
        limit = min(max(1, int(limit)), 100)
        return self._read(
            """
            MATCH (n {tenant_id: $tenant_id})-[r]-()
            WHERE r.first_seen_at IS NOT NULL
            WITH n, min(r.first_seen_at) AS first_seen
            RETURN n.name AS name, coalesce(labels(n)[0], 'Entity') AS type,
                   first_seen AS first_seen
            ORDER BY first_seen DESC, name ASC
            LIMIT toInteger($limit)
            """,
            {"tenant_id": tenant_id, "limit": limit},
        )

    def functional_relation_rows(
        self, tenant_id: str, relation_types: list[str]
    ) -> list[dict[str, Any]]:
        if not relation_types:
            return []
        return self._read(
            """
            MATCH (a {tenant_id: $tenant_id})-[r]->(b {tenant_id: $tenant_id})
            WHERE type(r) IN $relation_types
            RETURN a.name AS entity, type(r) AS relation,
                   collect(DISTINCT b.name) AS targets
            """,
            {"tenant_id": tenant_id, "relation_types": list(relation_types)},
        )


def _default_client(client: BriefingGraphClient | None) -> BriefingGraphClient:
    return client if client is not None else Neo4jBriefingClient()


def _top_communities(
    graph_client: BriefingGraphClient,
    tenant_id: str,
    min_community_size: int,
    limit: int,
    entities_per_community: int,
) -> list[dict[str, Any]]:
    rows = graph_client.communities(tenant_id, min_community_size)
    ranked = sorted(
        rows,
        key=lambda row: (-int(row.get("size") or 0), str(row.get("community") or "")),
    )[:limit]
    communities: list[dict[str, Any]] = []
    for row in ranked:
        members = [str(m) for m in (row.get("members") or []) if m]
        degrees = {
            entry.get("name"): entry
            for entry in graph_client.entity_degrees(tenant_id, members)
        }
        top_entities = sorted(
            (
                {
                    "name": name,
                    "type": (degrees.get(name) or {}).get("type"),
                    "degree": int((degrees.get(name) or {}).get("degree") or 0),
                }
                for name in members
            ),
            key=lambda item: (-item["degree"], item["name"]),
        )[:entities_per_community]
        communities.append(
            {
                "id": str(row.get("community") or ""),
                "size": int(row.get("size") or len(members)),
                "top_entities": top_entities,
            }
        )
    return communities


def _contradiction_flags(
    graph_client: BriefingGraphClient, tenant_id: str
) -> list[dict[str, Any]]:
    flags: list[dict[str, Any]] = []
    rows = graph_client.functional_relation_rows(
        tenant_id, list(FUNCTIONAL_RELATIONS)
    )
    for row in rows:
        targets = sorted({str(t) for t in (row.get("targets") or []) if t})
        if len(targets) < 2:
            continue
        flags.append(
            {
                "entity": row.get("entity"),
                "relation": row.get("relation"),
                "targets": targets,
            }
        )
    flags.sort(key=lambda f: (str(f.get("entity") or ""), str(f.get("relation") or "")))
    return flags


def build_briefing(
    tenant_id: str = "default",
    client: BriefingGraphClient | None = None,
    *,
    min_community_size: int = 1,
    top_communities_limit: int = 5,
    entities_per_community: int = 5,
    newest_limit: int = 10,
) -> dict[str, Any]:
    """Build the deterministic corpus briefing for ``tenant_id``.

    Returns ``{tenant, generated_from, top_communities,
    newest_entities, contradiction_flags, contradiction_rule}``.
    An empty corpus yields a valid briefing with zero counts and
    empty lists. No LLM is consulted at any point.
    """
    graph_client = _default_client(client)
    counts = graph_client.corpus_counts(tenant_id)
    nodes_by_label = dict(counts.get("nodes_by_label") or {})
    rels_by_type = dict(counts.get("relationships_by_type") or {})
    communities = _top_communities(
        graph_client,
        tenant_id,
        min_community_size,
        top_communities_limit,
        entities_per_community,
    )
    newest = [
        {
            "name": row.get("name"),
            "type": row.get("type"),
            "first_seen": row.get("first_seen"),
        }
        for row in graph_client.newest_entities(tenant_id, newest_limit)
        if row.get("first_seen") is not None
    ]
    return {
        "tenant": tenant_id,
        "generated_from": {
            "total_nodes": sum(nodes_by_label.values()),
            "total_relationships": sum(rels_by_type.values()),
            "nodes_by_label": nodes_by_label,
            "relationships_by_type": rels_by_type,
            "community_count": len(communities),
        },
        "top_communities": communities,
        "newest_entities": newest,
        "contradiction_flags": _contradiction_flags(graph_client, tenant_id),
        "contradiction_rule": CONTRADICTION_RULE,
    }


def render_briefing_markdown(briefing: dict[str, Any]) -> str:
    """Render a briefing dict from :func:`build_briefing` as markdown."""
    generated = briefing.get("generated_from") or {}
    lines = [
        f"# Corpus Briefing — {briefing.get('tenant', 'default')}",
        "",
        "## Overview",
        "",
        f"- Total nodes: {generated.get('total_nodes', 0)}",
        f"- Total relationships: {generated.get('total_relationships', 0)}",
        f"- Communities: {generated.get('community_count', 0)}",
        "",
        "## Top Communities",
        "",
    ]
    communities = briefing.get("top_communities") or []
    if not communities:
        lines.append("_No communities found._")
    for community in communities:
        lines.append(f"### Community {community.get('id')} (size {community.get('size')})")
        lines.append("")
        for entity in community.get("top_entities") or []:
            lines.append(
                f"- {entity.get('name')} ({entity.get('type') or 'Entity'})"
                f" — degree {entity.get('degree', 0)}"
            )
        lines.append("")
    lines += ["## Newest Entities", ""]
    newest = briefing.get("newest_entities") or []
    if not newest:
        lines.append("_No timestamped entities found._")
    for entity in newest:
        lines.append(
            f"- {entity.get('name')} ({entity.get('type') or 'Entity'})"
            f" — first seen {entity.get('first_seen')}"
        )
    lines += ["", "## Contradiction Flags", ""]
    lines.append(
        "_Heuristic only — see the contradiction rule in the structured "
        "briefing. A flag is a prompt for human review, not a verdict._"
    )
    lines.append("")
    flags = briefing.get("contradiction_flags") or []
    if not flags:
        lines.append("_No contradiction flags._")
    for flag in flags:
        targets = ", ".join(str(t) for t in flag.get("targets") or [])
        lines.append(
            f"- {flag.get('entity')} —{flag.get('relation')}→ {targets}"
        )
    lines.append("")
    return "\n".join(lines)


__all__ = [
    "CONTRADICTION_RULE",
    "FUNCTIONAL_RELATIONS",
    "BriefingGraphClient",
    "Neo4jBriefingClient",
    "build_briefing",
    "render_briefing_markdown",
]
