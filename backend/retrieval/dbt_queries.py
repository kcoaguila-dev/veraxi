"""Dataset-discovery query layer over the dbt lineage graph.

Queries run against an injectable :class:`DbtGraphClient` protocol so
tests can substitute an in-memory fake; the production implementation
is :class:`Neo4jDbtGraphClient`, which adapts the existing Neo4j
storage client and issues parameterized Cypher only.

Discovery semantics: a fragment matches a Dataset/Model when

* the node's ``name`` contains the fragment (case-insensitive), OR
* the node HAS_COLUMN a Column whose ``name`` equals the fragment
  exactly (case-insensitive) — column names are identifiers, so a
  substring match there would flood results.

Each match is returned with its one-hop lineage in both directions
(upstream = what it is built from, downstream = what is built from
it), read from the ``LINEAGE`` edges written by
:mod:`backend.ingestion.dbt_lineage`. Retrieval does not import
ingestion (pipeline direction), so the label/edge names are fixed
literals duplicated here, as in ``vuln_queries``.
"""

from __future__ import annotations

import logging
from typing import Any, Protocol, runtime_checkable

logger = logging.getLogger(__name__)

DATASET_LABELS = ("Dataset", "Model")


@runtime_checkable
class DbtGraphClient(Protocol):
    """Injectable graph-client interface for dataset discovery."""

    def find_by_name(
        self, tenant_id: str, fragment: str
    ) -> list[dict[str, Any]]:
        """Return Dataset/Model rows whose name contains ``fragment``."""
        ...

    def find_by_column(
        self, tenant_id: str, column_name: str
    ) -> list[dict[str, Any]]:
        """Return Dataset/Model rows having a column named ``column_name``."""
        ...

    def lineage(
        self, tenant_id: str, unique_ids: list[str]
    ) -> list[dict[str, Any]]:
        """Return one-hop LINEAGE rows touching any of ``unique_ids``.

        Each row: ``from_unique_id``, ``from_name``, ``from_label``,
        ``to_unique_id``, ``to_name``, ``to_label``.
        """
        ...


class Neo4jDbtGraphClient:
    """Production :class:`DbtGraphClient` over ``Neo4jStorageClient``.

    All user input travels as query parameters; no values are
    interpolated into the Cypher text.
    """

    _NODE_FIELDS = """
        labels(n)[0] AS label, n.name AS name,
        n.unique_id AS unique_id, n.resource_type AS resource_type,
        n.database AS database, n.schema AS schema,
        n.materialized AS materialized
    """

    def __init__(self, neo4j_client: Any = None) -> None:
        if neo4j_client is None:
            from backend.config import get_config
            from backend.storage.neo4j_client import Neo4jStorageClient

            neo4j_client = Neo4jStorageClient.from_config(get_config())
        self._client = neo4j_client

    def _read(self, query: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        return self._client.execute_read(query, params)

    def find_by_name(
        self, tenant_id: str, fragment: str
    ) -> list[dict[str, Any]]:
        query = f"""
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND (n:Dataset OR n:Model)
          AND toLower(n.name) CONTAINS toLower($fragment)
        RETURN {self._NODE_FIELDS}
        ORDER BY unique_id
        """
        return self._read(query, {"tenant_id": tenant_id, "fragment": fragment})

    def find_by_column(
        self, tenant_id: str, column_name: str
    ) -> list[dict[str, Any]]:
        query = f"""
        MATCH (n)-[:HAS_COLUMN]->(c:Column)
        WHERE n.tenant_id = $tenant_id
          AND c.tenant_id = $tenant_id
          AND (n:Dataset OR n:Model)
          AND toLower(c.name) = toLower($column_name)
        RETURN {self._NODE_FIELDS}
        ORDER BY unique_id
        """
        return self._read(
            query, {"tenant_id": tenant_id, "column_name": column_name}
        )

    def lineage(
        self, tenant_id: str, unique_ids: list[str]
    ) -> list[dict[str, Any]]:
        if not unique_ids:
            return []
        query = """
        MATCH (a)-[:LINEAGE]->(b)
        WHERE a.tenant_id = $tenant_id
          AND b.tenant_id = $tenant_id
          AND (a.unique_id IN $unique_ids OR b.unique_id IN $unique_ids)
        RETURN a.unique_id AS from_unique_id, a.name AS from_name,
               labels(a)[0] AS from_label,
               b.unique_id AS to_unique_id, b.name AS to_name,
               labels(b)[0] AS to_label
        """
        return self._read(
            query, {"tenant_id": tenant_id, "unique_ids": list(unique_ids)}
        )


def _default_client(client: DbtGraphClient | None) -> DbtGraphClient:
    return client if client is not None else Neo4jDbtGraphClient()


def dataset_discovery(
    query: str,
    tenant_id: str = "default",
    client: DbtGraphClient | None = None,
) -> dict[str, Any]:
    """Find datasets/models by name fragment or exact column name.

    Returns ``{query, matches}`` where each match is the node row
    plus ``matched_by`` (``"name"`` and/or ``"column"``),
    ``upstream`` and ``downstream`` one-hop lineage node summaries.
    """
    graph_client = _default_client(client)
    fragment = (query or "").strip()
    if not fragment:
        return {"query": fragment, "matches": []}

    by_unique_id: dict[str, dict[str, Any]] = {}
    for row in graph_client.find_by_name(tenant_id, fragment):
        entry = by_unique_id.setdefault(row["unique_id"], {**row, "matched_by": []})
        entry["matched_by"].append("name")
    for row in graph_client.find_by_column(tenant_id, fragment):
        entry = by_unique_id.setdefault(row["unique_id"], {**row, "matched_by": []})
        if "column" not in entry["matched_by"]:
            entry["matched_by"].append("column")

    unique_ids = sorted(by_unique_id)
    lineage_rows = graph_client.lineage(tenant_id, unique_ids)
    for entry in by_unique_id.values():
        upstream, downstream = [], []
        for row in lineage_rows:
            if row.get("to_unique_id") == entry["unique_id"]:
                upstream.append(
                    {
                        "unique_id": row.get("from_unique_id"),
                        "name": row.get("from_name"),
                        "label": row.get("from_label"),
                    }
                )
            if row.get("from_unique_id") == entry["unique_id"]:
                downstream.append(
                    {
                        "unique_id": row.get("to_unique_id"),
                        "name": row.get("to_name"),
                        "label": row.get("to_label"),
                    }
                )
        entry["upstream"] = sorted(upstream, key=lambda item: str(item["unique_id"]))
        entry["downstream"] = sorted(
            downstream, key=lambda item: str(item["unique_id"])
        )

    matches = [by_unique_id[uid] for uid in unique_ids]
    return {"query": fragment, "matches": matches}


__all__ = [
    "DATASET_LABELS",
    "DbtGraphClient",
    "Neo4jDbtGraphClient",
    "dataset_discovery",
]
