"""Tests for the Repo X-Ray query layer and MCP tools.

The query layer runs against an in-memory fake implementing the
CodeGraphClient protocol over a parsed fixture graph — no Neo4j,
no network. The Neo4j adapter is exercised with a recording stub to
prove its Cypher stays parameterized.
"""

import asyncio
from collections import Counter
from pathlib import Path

import pytest

from backend.ingestion.code_graph import CodeGraph, parse_repo
from backend.retrieval.code_queries import (
    Neo4jCodeGraphClient,
    code_source_url,
    impact_analysis,
    indexed_file,
    repo_overview,
    symbol_lookup,
)
from backend.tests.test_code_graph import FIXTURE_FILES


@pytest.fixture()
def parsed(tmp_path: Path) -> CodeGraph:
    root = tmp_path / "repo"
    for relative, content in FIXTURE_FILES.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    return parse_repo(root)


class FakeCodeGraphClient:
    """In-memory CodeGraphClient over a parsed CodeGraph."""

    def __init__(self, graph: CodeGraph):
        self.graph = graph
        self._by_qn = {node.qualified_name: node for node in graph.nodes}

    def _row(self, node):
        return {
            "label": node.label,
            "name": node.name,
            "qualified_name": node.qualified_name,
            "path": node.path,
            "line": node.line,
            "end_line": node.end_line,
            "language": node.language,
            "repo_key": node.repo_key,
        }

    def find_symbols(self, tenant_id, *, qualified_name=None, name=None, repo_key=None):
        return [
            self._row(node)
            for node in self.graph.nodes
            if (
                (qualified_name is not None and node.qualified_name == qualified_name)
                or (qualified_name is None and name is not None and node.name == name)
            )
            and (repo_key is None or node.repo_key == repo_key)
        ]

    def find_file(self, tenant_id, path):
        for node in self.graph.nodes:
            if node.label == "CodeFile" and node.path == path:
                return self._row(node)
        return None

    def incoming_edges(self, tenant_id, target_qns, repo_key=None):
        rows = []
        for edge in self.graph.edges:
            if edge.type not in ("CALLS", "IMPORTS"):
                continue
            if edge.target_qn not in target_qns:
                continue
            if repo_key is not None and edge.repo_key != repo_key:
                continue
            source = self._by_qn.get(edge.source_qn)
            if source is None:
                continue
            rows.append(
                {
                    "source_qn": edge.source_qn,
                    "source_name": source.name,
                    "source_label": source.label,
                    "source_path": source.path,
                    "source_line": source.line,
                    "source_end_line": source.end_line,
                    "source_repo_key": source.repo_key,
                    "edge_type": edge.type,
                    "target_qn": edge.target_qn,
                }
            )
        return rows

    def index_meta(self, tenant_id, repo_key=None):
        # The fixture graph is parsed in memory and never ingested:
        # no provenance stamp exists for it.
        return None

    def index_metas(self, tenant_id):
        return []

    def _scoped_nodes(self, path_prefix, repo_key=None):
        return [
            node
            for node in self.graph.nodes
            if (path_prefix is None or node.path.startswith(path_prefix))
            and (repo_key is None or node.repo_key == repo_key)
        ]

    def node_counts(self, tenant_id, path_prefix=None, repo_key=None):
        return dict(Counter(n.label for n in self._scoped_nodes(path_prefix, repo_key)))

    def edge_counts(self, tenant_id, path_prefix=None, repo_key=None):
        scoped = {
            (n.repo_key, n.qualified_name)
            for n in self._scoped_nodes(path_prefix, repo_key)
        }
        return dict(
            Counter(
                edge.type
                for edge in self.graph.edges
                if (edge.repo_key, edge.source_qn) in scoped
            )
        )

    def top_connected(self, tenant_id, path_prefix=None, limit=10, repo_key=None):
        degree: Counter = Counter()
        for edge in self.graph.edges:
            degree[(edge.repo_key, edge.source_qn)] += 1
            degree[(edge.repo_key, edge.target_qn)] += 1
        rows = []
        for node in self._scoped_nodes(path_prefix, repo_key):
            rows.append(
                {
                    "qualified_name": node.qualified_name,
                    "name": node.name,
                    "label": node.label,
                    "path": node.path,
                    "repo_key": node.repo_key,
                    "connections": degree[(node.repo_key, node.qualified_name)],
                }
            )
        rows.sort(key=lambda r: (-r["connections"], r["qualified_name"]))
        return rows[:limit]


@pytest.fixture()
def fake(parsed) -> FakeCodeGraphClient:
    return FakeCodeGraphClient(parsed)


def test_symbol_lookup_exact_qualified_first(fake):
    result = symbol_lookup("pkg.helpers.shout", tenant_id="t", client=fake)
    assert result["match_type"] == "qualified_name"
    assert [m["qualified_name"] for m in result["matches"]] == ["pkg.helpers.shout"]


def test_symbol_lookup_simple_name_fallback(fake):
    result = symbol_lookup("shout", tenant_id="t", client=fake)
    assert result["match_type"] == "name"
    assert {m["qualified_name"] for m in result["matches"]} == {
        "pkg.helpers.shout",
        "pkg.other.shout",
    }


def test_symbol_lookup_missing(fake):
    result = symbol_lookup("does_not_exist", tenant_id="t", client=fake)
    assert result["match_type"] is None
    assert result["matches"] == []


def test_indexed_file_returns_code_file_row(fake):
    row = indexed_file("pkg/helpers.py", tenant_id="t", client=fake)
    assert row is not None
    assert row["path"] == "pkg/helpers.py"
    assert row["label"] == "CodeFile"
    assert row["language"] == "python"


def test_indexed_file_missing_path(fake):
    assert indexed_file("pkg/nope.py", tenant_id="t", client=fake) is None


def test_indexed_file_blank_path(fake):
    assert indexed_file("", tenant_id="t", client=fake) is None
    assert indexed_file("   ", tenant_id="t", client=fake) is None


def test_impact_transitive_callers(fake):
    result = impact_analysis("pkg.helpers.shout", tenant_id="t", client=fake)
    assert result["found"] is True
    by_qn = {item["qualified_name"]: item for item in result["impacted"]}
    assert by_qn["pkg.core.render"]["depth"] == 1
    assert by_qn["pkg.core.render"]["via_edge"] == "CALLS"
    assert by_qn["pkg.core.LoudGreeter.greet"]["depth"] == 1
    assert by_qn["pkg.app.main"]["depth"] == 2
    assert by_qn["cli.run"]["depth"] == 3
    # The symbol itself is never reported as impacted.
    assert "pkg.helpers.shout" not in by_qn


def test_impact_respects_max_depth(fake):
    result = impact_analysis(
        "pkg.helpers.shout", tenant_id="t", max_depth=1, client=fake
    )
    qns = {item["qualified_name"] for item in result["impacted"]}
    assert "pkg.core.render" in qns
    assert "pkg.app.main" not in qns


def test_impact_via_imports_on_module(fake):
    result = impact_analysis("pkg.helpers", tenant_id="t", client=fake)
    by_qn = {item["qualified_name"]: item for item in result["impacted"]}
    assert by_qn["pkg.core"]["depth"] == 1
    assert by_qn["pkg.core"]["via_edge"] == "IMPORTS"
    assert by_qn["pkg.app"]["depth"] == 2
    assert by_qn["cli"]["depth"] == 3


def test_impact_unknown_symbol(fake):
    result = impact_analysis("nope", tenant_id="t", client=fake)
    assert result["found"] is False
    assert result["impacted"] == []


def test_repo_overview_counts(fake, parsed):
    result = repo_overview(tenant_id="t", client=fake)
    assert result["total_nodes"] == len(parsed.nodes)
    assert result["total_edges"] == len(parsed.edges)
    assert result["node_counts"]["Class"] >= 3
    assert result["node_counts"]["Function"] >= 6
    assert result["edge_counts"]["CALLS"] >= 5
    assert result["edge_counts"]["IMPORTS"] >= 5
    connections = [row["connections"] for row in result["top_connected"]]
    assert connections == sorted(connections, reverse=True)
    assert connections[0] > 0


def test_repo_overview_path_prefix(fake):
    result = repo_overview(tenant_id="t", path_prefix="lib/", client=fake)
    assert result["node_counts"] == {"CodeFile": 1, "CodeModule": 1, "Class": 1, "Function": 1}


# ---------------------------------------------------------------------------
# Citation URLs (file:// with line anchors)
# ---------------------------------------------------------------------------


def test_code_source_url_variants():
    # Full range when both lines are known.
    assert (
        code_source_url("pkg/helpers.py", 1, 2) == "file://pkg/helpers.py#L1-L2"
    )
    # Start line only: single-line anchor, no invented end.
    assert code_source_url("pkg/helpers.py", 5, None) == "file://pkg/helpers.py#L5"
    assert code_source_url("pkg/helpers.py", 5, 5) == "file://pkg/helpers.py#L5"
    # No usable line data: plain file URL, no anchor.
    assert code_source_url("pkg/helpers.py", None, None) == "file://pkg/helpers.py"
    assert code_source_url("pkg/helpers.py", 0, None) == "file://pkg/helpers.py"
    # No path: no citation target at all.
    assert code_source_url("", 1, 2) is None
    assert code_source_url(None, 1, 2) is None


def test_symbol_lookup_match_carries_line_anchored_url(fake):
    result = symbol_lookup("pkg.helpers.shout", tenant_id="t", client=fake)
    match = result["matches"][0]
    assert match["line"] == 1
    assert match["end_line"] == 2
    assert match["url"] == "file://pkg/helpers.py#L1-L2"


def test_impact_entries_carry_line_anchored_urls(fake):
    result = impact_analysis("pkg.helpers.shout", tenant_id="t", client=fake)
    assert result["roots"][0]["url"] == "file://pkg/helpers.py#L1-L2"
    by_qn = {item["qualified_name"]: item for item in result["impacted"]}
    render = by_qn["pkg.core.render"]
    assert render["line"] == 10
    assert render["end_line"] == 11
    assert render["url"] == "file://pkg/core.py#L10-L11"
    greet = by_qn["pkg.core.LoudGreeter.greet"]
    assert greet["url"] == "file://pkg/core.py#L6-L7"


def test_repo_overview_top_connected_plain_file_urls(fake):
    result = repo_overview(tenant_id="t", client=fake)
    assert result["top_connected"]
    for row in result["top_connected"]:
        # top_connected rows carry a path but no line: plain file:// URL.
        assert row["url"] == f"file://{row['path']}"
        assert "#" not in row["url"]


# ---------------------------------------------------------------------------
# MCP tool wrappers + registration
# ---------------------------------------------------------------------------


def test_mcp_tools_return_dicts(fake):
    from backend.mcp_server.tools.code_tools import (
        code_impact,
        code_overview,
        code_symbol,
        tool_schemas,
    )

    assert {d["function"]["name"] for d in tool_schemas()} == {
        "code_symbol",
        "code_impact",
        "code_overview",
    }
    symbol = code_symbol("pkg.helpers.shout", tenant_id="t", client=fake)
    assert symbol["matches"][0]["qualified_name"] == "pkg.helpers.shout"
    impact = code_impact("shout", tenant_id="t", client=fake)
    assert impact["found"] is True
    overview = code_overview(tenant_id="t", client=fake)
    assert overview["total_nodes"] > 0


def test_tools_registered_in_dispatch_and_mcp_server(fake, monkeypatch):
    from backend.mcp_server.handlers.tool_registry import TOOL_HANDLERS
    from backend.mcp_server.handlers.tool_schemas import REGISTERED_TOOLS
    from backend.mcp_server.tool_dispatch import get_tools

    names = {tool.name for tool in REGISTERED_TOOLS}
    assert {"mcp_code_symbol", "mcp_code_impact", "mcp_code_overview"} <= names
    assert {"mcp_code_symbol", "mcp_code_impact", "mcp_code_overview"} <= set(
        TOOL_HANDLERS
    )

    tools = asyncio.run(get_tools({"file_search_enabled": True}, tenant_id="t"))
    function_names = {t["function"]["name"] for t in tools}
    assert {"code_symbol", "code_impact", "code_overview"} <= function_names


def test_dispatch_execute_single_tool(monkeypatch, fake):
    import backend.mcp_server.tools.code_tools as code_tools_module
    from backend.mcp_server.tool_dispatch import _execute_single_tool

    original = code_tools_module.code_symbol
    monkeypatch.setattr(
        code_tools_module,
        "code_symbol",
        lambda name, tenant_id="default", client=None: original(
            name, tenant_id=tenant_id, client=fake
        ),
    )
    hits, graph_hits = _execute_single_tool(
        "code_symbol",
        {"name": "pkg.helpers.shout"},
        "t",
        {"file_search_enabled": True},
    )
    assert graph_hits == []
    assert hits[0].payload["matches"][0]["name"] == "shout"
    assert hits[0].sources == ["Repo X-Ray"]

    # Gated off like query_graph when file search is disabled.
    hits, graph_hits = _execute_single_tool(
        "code_symbol", {"name": "x"}, "t", {"file_search_enabled": False}
    )
    assert hits == [] and graph_hits == []


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
    client = Neo4jCodeGraphClient(stub)
    client.find_symbols("tenant-a", qualified_name="pkg.helpers.shout")
    client.find_symbols("tenant-a", name="shout")
    client.incoming_edges("tenant-a", ["pkg.helpers.shout"])
    client.node_counts("tenant-a", "pkg/")
    client.edge_counts("tenant-a")
    client.top_connected("tenant-a", limit=5)

    assert len(stub.calls) == 6
    for query, params in stub.calls:
        assert "tenant-a" not in query
        assert "pkg.helpers.shout" not in query
        assert params["tenant_id"] == "tenant-a"
    assert stub.calls[2][1]["target_qns"] == ["pkg.helpers.shout"]
    assert stub.calls[2][1]["edge_types"] == ["CALLS", "IMPORTS"]
