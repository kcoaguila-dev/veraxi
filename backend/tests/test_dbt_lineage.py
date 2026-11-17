"""Tests for the dbt lineage data pack (Phase 6b).

Parser tests run on a fixture manifest dict; the writer is exercised
with a fake client recording its calls; discovery runs against an
in-memory fake implementing the DbtGraphClient protocol over the
parsed fixture graph — no Neo4j, no network.
"""

import asyncio

from backend.ingestion.dbt_lineage import parse_dbt_manifest, write_dbt_graph
from backend.retrieval.dbt_queries import Neo4jDbtGraphClient, dataset_discovery

FIXTURE_MANIFEST = {
    "nodes": {
        "model.proj.stg_users": {
            "resource_type": "model",
            "name": "stg_users",
            "schema": "analytics",
            "database": "warehouse",
            "config": {"materialized": "view"},
            "columns": {
                "user_id": {"name": "user_id", "data_type": "integer"},
                "email": {"name": "email", "data_type": "text"},
            },
            "depends_on": {"nodes": ["source.proj.raw.raw_users"]},
        },
        "model.proj.dim_users": {
            "resource_type": "model",
            "name": "dim_users",
            "schema": "analytics",
            "database": "warehouse",
            "config": {"materialized": "table"},
            "columns": {
                "user_id": {"name": "user_id", "data_type": "integer"},
                "signup_date": {"name": "signup_date", "data_type": "date"},
            },
            "depends_on": {"nodes": ["model.proj.stg_users"]},
        },
        "model.proj.fct_signups": {
            "resource_type": "model",
            "name": "fct_signups",
            "schema": "analytics",
            "database": "warehouse",
            "config": {"materialized": "ephemeral"},
            "columns": {
                "signup_date": {"name": "signup_date", "data_type": "date"},
                "signups": {"name": "signups", "data_type": "integer"},
            },
            "depends_on": {"nodes": ["model.proj.dim_users"]},
        },
        "test.proj.unique_stg_users": {
            "resource_type": "test",
            "name": "unique_stg_users",
            "depends_on": {"nodes": ["model.proj.stg_users"]},
        },
    },
    "sources": {
        "source.proj.raw.raw_users": {
            "resource_type": "source",
            "name": "raw_users",
            "schema": "raw",
            "database": "warehouse",
            "columns": {
                "user_id": {"name": "user_id", "data_type": "integer"},
                "email": {"name": "email", "data_type": "text"},
            },
        },
        "source.proj.raw.raw_events": {
            "resource_type": "source",
            "name": "raw_events",
            "schema": "raw",
            "database": "warehouse",
            "columns": {
                "event_id": {"name": "event_id", "data_type": "integer"},
            },
        },
    },
    # Derived views of depends_on — the parser must NOT use these,
    # or lineage edges would be double-counted.
    "child_map": {"source.proj.raw.raw_users": ["model.proj.stg_users"]},
    "parent_map": {"model.proj.stg_users": ["source.proj.raw.raw_users"]},
}


def _parsed():
    return parse_dbt_manifest(FIXTURE_MANIFEST)


def test_parse_node_mapping():
    graph = _parsed()
    by_uid = {node.unique_id: node for node in graph.nodes}
    # Sources are Datasets.
    assert by_uid["source.proj.raw.raw_users"].label == "Dataset"
    assert by_uid["source.proj.raw.raw_events"].label == "Dataset"
    # View/ephemeral models are Models; the table model is a Dataset.
    assert by_uid["model.proj.stg_users"].label == "Model"
    assert by_uid["model.proj.dim_users"].label == "Dataset"
    assert by_uid["model.proj.fct_signups"].label == "Model"
    # Tests are not nodes.
    assert "test.proj.unique_stg_users" not in by_uid
    dataset_model = [n for n in graph.nodes if n.label in ("Dataset", "Model")]
    assert len(dataset_model) == 5


def test_parse_columns_and_has_column_edges():
    graph = _parsed()
    columns = [n for n in graph.nodes if n.label == "Column"]
    assert len(columns) == 9  # 2+2+2+2+1 across the five resources
    user_id = graph.node("Column", "model.proj.stg_users::user_id")
    assert user_id is not None
    assert user_id.data_type == "integer"
    assert user_id.parent_unique_id == "model.proj.stg_users"
    has_column = graph.edges_of("HAS_COLUMN")
    assert len(has_column) == 9
    assert all(e.target_label == "Column" for e in has_column)


def test_parse_lineage_direction_from_depends_on():
    graph = _parsed()
    lineage = {
        (e.source_unique_id, e.target_unique_id) for e in graph.edges_of("LINEAGE")
    }
    assert lineage == {
        ("source.proj.raw.raw_users", "model.proj.stg_users"),
        ("model.proj.stg_users", "model.proj.dim_users"),
        ("model.proj.dim_users", "model.proj.fct_signups"),
    }


# ---------------------------------------------------------------------------
# Writer (fake client)
# ---------------------------------------------------------------------------


class RecordingWriteClient:
    def __init__(self):
        self.calls = []

    def execute_write(self, query, parameters=None):
        self.calls.append((query, parameters or {}))
        return []


def test_writer_fake_client_parameterized_and_keyed():
    graph = _parsed()
    client = RecordingWriteClient()
    result = write_dbt_graph(client, graph, tenant_id="t1")
    assert result == {
        "nodes_written": len(graph.nodes),
        "edges_written": len(graph.edges),
    }
    assert len(client.calls) == len(graph.nodes) + len(graph.edges)
    for query, params in client.calls:
        # Tenant / names travel as parameters, never in the Cypher text.
        assert "t1::" not in query
        assert "raw_users" not in query
    node_params = [p for _q, p in client.calls if "dbt_key" in p]
    assert any(
        p["dbt_key"] == "t1::Dataset::source.proj.raw.raw_users" for p in node_params
    )
    assert all("qdrant" not in str(p).lower() for p in node_params)


# ---------------------------------------------------------------------------
# Discovery (in-memory fake over the parsed fixture)
# ---------------------------------------------------------------------------


class FakeDbtClient:
    """In-memory DbtGraphClient over a parsed DbtGraph."""

    def __init__(self, graph):
        self.graph = graph
        self._datasets = [n for n in graph.nodes if n.label in ("Dataset", "Model")]
        self._columns_by_parent = {}
        for edge in graph.edges_of("HAS_COLUMN"):
            self._columns_by_parent.setdefault(edge.source_unique_id, []).append(
                edge.target_unique_id.rsplit("::", 1)[-1]
            )

    def _row(self, node):
        return {
            "label": node.label,
            "name": node.name,
            "unique_id": node.unique_id,
            "resource_type": node.resource_type,
            "database": node.database,
            "schema": node.schema,
            "materialized": node.materialized,
        }

    def find_by_name(self, tenant_id, fragment):
        return [
            self._row(n) for n in self._datasets if fragment.lower() in n.name.lower()
        ]

    def find_by_column(self, tenant_id, column_name):
        return [
            self._row(n)
            for n in self._datasets
            if column_name.lower()
            in [c.lower() for c in self._columns_by_parent.get(n.unique_id, [])]
        ]

    def lineage(self, tenant_id, unique_ids):
        by_uid = {n.unique_id: n for n in self.graph.nodes}
        rows = []
        for edge in self.graph.edges_of("LINEAGE"):
            if edge.source_unique_id in unique_ids or edge.target_unique_id in unique_ids:
                source, target = by_uid[edge.source_unique_id], by_uid[edge.target_unique_id]
                rows.append(
                    {
                        "from_unique_id": source.unique_id,
                        "from_name": source.name,
                        "from_label": source.label,
                        "to_unique_id": target.unique_id,
                        "to_name": target.name,
                        "to_label": target.label,
                    }
                )
        return rows


def test_discovery_by_column_returns_models_and_lineage():
    result = dataset_discovery("user_id", tenant_id="t", client=FakeDbtClient(_parsed()))
    by_name = {m["name"]: m for m in result["matches"]}
    assert set(by_name) == {"raw_users", "stg_users", "dim_users"}
    assert all("column" in m["matched_by"] for m in result["matches"])
    stg = by_name["stg_users"]
    assert [u["name"] for u in stg["upstream"]] == ["raw_users"]
    assert [d["name"] for d in stg["downstream"]] == ["dim_users"]
    dim = by_name["dim_users"]
    assert [u["name"] for u in dim["upstream"]] == ["stg_users"]
    assert [d["name"] for d in dim["downstream"]] == ["fct_signups"]


def test_discovery_by_name_fragment():
    result = dataset_discovery("users", tenant_id="t", client=FakeDbtClient(_parsed()))
    names = {m["name"] for m in result["matches"]}
    assert names == {"raw_users", "stg_users", "dim_users"}
    assert all(m["matched_by"] == ["name"] for m in result["matches"])


def test_discovery_no_match_and_empty_query():
    fake = FakeDbtClient(_parsed())
    assert dataset_discovery("nope", tenant_id="t", client=fake)["matches"] == []
    assert dataset_discovery("  ", tenant_id="t", client=fake)["matches"] == []


# ---------------------------------------------------------------------------
# MCP tool wrapper + registration
# ---------------------------------------------------------------------------


def test_mcp_tool_and_registration(monkeypatch):
    from backend.mcp_server.handlers.tool_registry import TOOL_HANDLERS
    from backend.mcp_server.handlers.tool_schemas import REGISTERED_TOOLS
    from backend.mcp_server.tool_dispatch import get_tools
    from backend.mcp_server.tools.dbt_tools import dataset_discovery as tool
    from backend.mcp_server.tools.dbt_tools import tool_schemas

    assert {d["function"]["name"] for d in tool_schemas()} == {"dataset_discovery"}
    result = tool("user_id", tenant_id="t", client=FakeDbtClient(_parsed()))
    assert {m["name"] for m in result["matches"]} == {
        "raw_users", "stg_users", "dim_users",
    }

    assert "mcp_dataset_discovery" in {t.name for t in REGISTERED_TOOLS}
    assert "mcp_dataset_discovery" in TOOL_HANDLERS
    tools = asyncio.run(get_tools({"file_search_enabled": True}, tenant_id="t"))
    assert "dataset_discovery" in {t["function"]["name"] for t in tools}


def test_dispatch_execute_single_tool(monkeypatch):
    import backend.mcp_server.tools.dbt_tools as dbt_tools_module
    from backend.mcp_server.tool_dispatch import _execute_single_tool

    original = dbt_tools_module.dataset_discovery
    monkeypatch.setattr(
        dbt_tools_module,
        "dataset_discovery",
        lambda query, tenant_id="default", client=None: original(
            query, tenant_id=tenant_id, client=FakeDbtClient(_parsed())
        ),
    )
    hits, graph_hits = _execute_single_tool(
        "dataset_discovery", {"query": "user_id"}, "t",
        {"file_search_enabled": True},
    )
    assert graph_hits == []
    assert hits[0].sources == ["Data Lineage"]
    assert hits[0].payload["matches"]


# ---------------------------------------------------------------------------
# Neo4j adapter: parameterized Cypher only
# ---------------------------------------------------------------------------


class RecordingNeo4jStub:
    def __init__(self):
        self.calls = []

    def execute_read(self, query, parameters=None):
        self.calls.append((query, parameters or {}))
        return []


def test_neo4j_adapter_parameterized():
    stub = RecordingNeo4jStub()
    client = Neo4jDbtGraphClient(stub)
    client.find_by_name("tenant-a", "users")
    client.find_by_column("tenant-a", "user_id")
    client.lineage("tenant-a", ["model.proj.stg_users"])

    assert len(stub.calls) == 3
    for query, params in stub.calls:
        assert "tenant-a" not in query
        assert "user_id" not in query
        assert "model.proj.stg_users" not in query
        assert params["tenant_id"] == "tenant-a"
    assert stub.calls[0][1]["fragment"] == "users"
    assert stub.calls[2][1]["unique_ids"] == ["model.proj.stg_users"]
