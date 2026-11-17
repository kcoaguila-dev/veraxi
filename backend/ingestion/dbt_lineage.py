"""Data pack: parse a dbt ``manifest.json`` into a lineage graph.

Two separable halves, mirroring :mod:`backend.ingestion.code_graph`:

* :func:`parse_dbt_manifest` — pure parsing. Takes the decoded
  manifest dict and returns an in-memory :class:`DbtGraph` (nodes +
  edges) with no database, network or LLM involved.
* :func:`write_dbt_graph` — persistence. Writes a parsed graph to
  Neo4j through the existing storage client, following
  ``code_graph.py`` patterns: tenant-scoped, parameterized Cypher
  only (labels and relationship types come from fixed whitelists in
  this module, never from user input), keyed by a ``dbt_key`` in the
  ``code_key`` style.

Node mapping (documented, deterministic):

* dbt **sources** (top-level ``sources`` in the manifest) become
  ``Dataset`` nodes — they are physical external tables.
* dbt **models / seeds / snapshots** (``nodes`` with those
  ``resource_type`` values) become ``Model`` nodes, EXCEPT resources
  materialized as physical tables — ``config.materialized`` (or a
  top-level ``materialized``) of ``"table"`` or ``"incremental"`` —
  which become ``Dataset`` nodes instead: they are physical datasets
  other models read from, exactly like sources. A resource gets
  exactly ONE dataset/model node (never both), so lineage stays a
  simple chain.
* dbt **tests** and any other resource types are skipped as nodes:
  a test is a check on a dataset, not a dataset itself. (Their
  ``depends_on`` entries therefore never create lineage edges.)
* ``Column`` nodes come from each resource's ``columns`` dict
  (name + ``data_type`` when dbt recorded one).

Edges:

* ``LINEAGE`` — upstream node -> downstream model, from the
  downstream resource's ``depends_on.nodes`` list. ``depends_on`` is
  canonical; ``child_map`` / ``parent_map`` are derived views of the
  same data in dbt and are deliberately not used, so an edge is
  never double-counted. Only edges where BOTH ends resolved to a
  Dataset/Model node are emitted.
* ``HAS_COLUMN`` — Dataset/Model node -> its ``Column`` nodes.

Qdrant note (per ``docs/evidence-first-plan.md``): dbt lineage nodes
are structural metadata parsed from a manifest, NOT text chunks, so
they carry NO Qdrant point ID and the chunk dual-write rule does not
apply to them — the same documented rationale as code-graph and
vuln-intel nodes.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)

NODE_LABELS = ("Dataset", "Model", "Column")
EDGE_TYPES = ("LINEAGE", "HAS_COLUMN")
MODEL_RESOURCE_TYPES = ("model", "seed", "snapshot")
TABLE_MATERIALIZATIONS = ("table", "incremental")


@dataclass
class LineageNode:
    """One dbt lineage node (Dataset, Model or Column)."""

    label: str
    name: str
    unique_id: str
    resource_type: str = ""
    database: str = ""
    schema: str = ""
    materialized: str = ""
    data_type: str = ""
    parent_unique_id: str = ""

    @property
    def key(self) -> tuple[str, str]:
        return (self.label, self.unique_id)

    def properties(self, tenant_id: str) -> dict[str, Any]:
        return {
            "name": self.name,
            "unique_id": self.unique_id,
            "resource_type": self.resource_type,
            "database": self.database,
            "schema": self.schema,
            "materialized": self.materialized,
            "data_type": self.data_type,
            "parent_unique_id": self.parent_unique_id,
            "tenant_id": tenant_id,
        }


@dataclass
class LineageEdge:
    """One directed edge between two nodes, by manifest unique_id."""

    type: str
    source_unique_id: str
    source_label: str
    target_unique_id: str
    target_label: str


@dataclass
class DbtGraph:
    """In-memory lineage graph: the pure output of the parser."""

    nodes: list[LineageNode] = field(default_factory=list)
    edges: list[LineageEdge] = field(default_factory=list)

    def node(self, label: str, unique_id: str) -> LineageNode | None:
        for node in self.nodes:
            if node.label == label and node.unique_id == unique_id:
                return node
        return None

    def edges_of(self, edge_type: str) -> list[LineageEdge]:
        return [edge for edge in self.edges if edge.type == edge_type]


def _materialized_of(resource: dict[str, Any]) -> str:
    config = resource.get("config") or {}
    value = config.get("materialized") or resource.get("materialized") or ""
    return str(value).strip().lower()


def _label_for_resource(resource: dict[str, Any], unique_id: str) -> str | None:
    """Map one manifest resource to its node label, or None to skip it."""
    resource_type = str(resource.get("resource_type") or "")
    if unique_id.startswith("source.") or resource_type == "source":
        return "Dataset"
    if resource_type not in MODEL_RESOURCE_TYPES:
        return None
    if _materialized_of(resource) in TABLE_MATERIALIZATIONS:
        return "Dataset"
    return "Model"


def _add_columns(
    nodes: dict[tuple[str, str], LineageNode],
    edges: dict[tuple[str, str, str], LineageEdge],
    parent: LineageNode,
    resource: dict[str, Any],
) -> None:
    columns = resource.get("columns") or {}
    if not isinstance(columns, dict):
        return
    for column_name in sorted(columns):
        column = columns[column_name] or {}
        unique_id = f"{parent.unique_id}::{column_name}"
        node = LineageNode(
            label="Column",
            name=str(column_name),
            unique_id=unique_id,
            resource_type="column",
            data_type=str(column.get("data_type") or ""),
            parent_unique_id=parent.unique_id,
        )
        nodes[node.key] = node
        edge_key = ("HAS_COLUMN", parent.unique_id, unique_id)
        edges[edge_key] = LineageEdge(
            type="HAS_COLUMN",
            source_unique_id=parent.unique_id,
            source_label=parent.label,
            target_unique_id=unique_id,
            target_label="Column",
        )


def _add_lineage_edges(
    nodes: dict[tuple[str, str], LineageNode],
    edges: dict[tuple[str, str, str], LineageEdge],
    resources: dict[str, dict[str, Any]],
) -> None:
    by_unique_id = {node.unique_id: node for node in nodes.values() if node.label != "Column"}
    for unique_id, resource in resources.items():
        downstream = by_unique_id.get(unique_id)
        if downstream is None:
            continue
        depends_on = resource.get("depends_on") or {}
        for upstream_id in depends_on.get("nodes") or []:
            upstream = by_unique_id.get(str(upstream_id))
            if upstream is None or upstream.unique_id == downstream.unique_id:
                continue
            edge_key = ("LINEAGE", upstream.unique_id, downstream.unique_id)
            edges[edge_key] = LineageEdge(
                type="LINEAGE",
                source_unique_id=upstream.unique_id,
                source_label=upstream.label,
                target_unique_id=downstream.unique_id,
                target_label=downstream.label,
            )


def parse_dbt_manifest(payload: dict) -> DbtGraph:
    """Parse a decoded dbt ``manifest.json`` dict into a :class:`DbtGraph`.

    Pure: no database or network access. ``payload`` is the manifest
    as decoded JSON (``nodes`` and ``sources`` are dicts keyed by
    dbt unique_id, as dbt writes them).
    """
    nodes: dict[tuple[str, str], LineageNode] = {}
    edges: dict[tuple[str, str, str], LineageEdge] = {}
    resources: dict[str, dict[str, Any]] = {}
    for section in ("nodes", "sources"):
        entries = payload.get(section) or {}
        if isinstance(entries, dict):
            resources.update(entries)

    for unique_id, resource in sorted(resources.items()):
        if not isinstance(resource, dict):
            continue
        label = _label_for_resource(resource, str(unique_id))
        if label is None:
            continue
        node = LineageNode(
            label=label,
            name=str(resource.get("name") or unique_id),
            unique_id=str(unique_id),
            resource_type=str(resource.get("resource_type") or ""),
            database=str(resource.get("database") or ""),
            schema=str(resource.get("schema") or ""),
            materialized=_materialized_of(resource),
        )
        nodes[node.key] = node
        _add_columns(nodes, edges, node, resource)

    _add_lineage_edges(nodes, edges, resources)
    return DbtGraph(nodes=list(nodes.values()), edges=list(edges.values()))


# ---------------------------------------------------------------------------
# Neo4j writer (code_graph.py patterns: tenant-scoped, parameterized)
# ---------------------------------------------------------------------------


def _write_node(client: Any, node: LineageNode, tenant_id: str) -> None:
    from backend.ingestion.graph_write import structural_key, upsert_structural_node

    upsert_structural_node(
        client,
        label=node.label,
        allowed_labels=NODE_LABELS,
        key_field="dbt_key",
        key_value=structural_key(tenant_id, node.label, node.unique_id),
        properties=node.properties(tenant_id),
    )


def _write_edge(client: Any, edge: LineageEdge, tenant_id: str) -> None:
    from backend.ingestion.graph_write import structural_key, upsert_structural_edge

    upsert_structural_edge(
        client,
        edge_type=edge.type,
        allowed_edge_types=EDGE_TYPES,
        key_field="dbt_key",
        from_key=structural_key(tenant_id, edge.source_label, edge.source_unique_id),
        to_key=structural_key(tenant_id, edge.target_label, edge.target_unique_id),
        tenant_id=tenant_id,
    )


def write_dbt_graph(
    client: Any, graph: DbtGraph, tenant_id: str = "default"
) -> dict[str, int]:
    """Persist a parsed :class:`DbtGraph` to Neo4j via ``client``.

    ``client`` is the existing Neo4j storage client (anything exposing
    ``execute_write(query, parameters)``, e.g. ``Neo4jStorageClient``).
    Every query is parameterized; labels/relationship types are
    interpolated only from this module's whitelists. Dbt nodes carry
    no Qdrant point ID (see module docstring). Returns write counts.
    """
    for node in graph.nodes:
        _write_node(client, node, tenant_id)
    for edge in graph.edges:
        _write_edge(client, edge, tenant_id)
    return {"nodes_written": len(graph.nodes), "edges_written": len(graph.edges)}


__all__ = [
    "EDGE_TYPES",
    "NODE_LABELS",
    "DbtGraph",
    "LineageEdge",
    "LineageNode",
    "parse_dbt_manifest",
    "write_dbt_graph",
]
