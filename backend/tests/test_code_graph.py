"""Tests for Repo X-Ray parsing (pure) and the Neo4j writer (faked).

No network, no Docker, no live Neo4j: parsing runs on a fixture
mini-repo built under tmp_path, and the writer runs against a fake
client that records the parameterized calls it receives.
"""

from pathlib import Path

import pytest

from backend.ingestion.code_graph import parse_repo, write_code_graph

FIXTURE_FILES = {
    "pkg/__init__.py": "",
    "pkg/helpers.py": (
        "def shout(text):\n"
        "    return text.upper()\n"
        "\n"
        "\n"
        "def whisper(text):\n"
        "    return text.lower()\n"
    ),
    "pkg/other.py": (
        "def shout(text):\n"
        "    return '[' + text + ']'\n"
    ),
    "pkg/base.py": (
        "class BaseGreeter:\n"
        "    def greet(self):\n"
        "        return 'hello'\n"
        "\n"
        "    def greet_loudly(self):\n"
        "        return self.greet().upper()\n"
    ),
    "pkg/core.py": (
        "from pkg.base import BaseGreeter\n"
        "from pkg.helpers import shout\n"
        "\n"
        "\n"
        "class LoudGreeter(BaseGreeter):\n"
        "    def greet(self):\n"
        "        return shout('hello')\n"
        "\n"
        "\n"
        "def render():\n"
        "    return shout('rendered')\n"
    ),
    "pkg/app.py": (
        "from pkg.core import render\n"
        "\n"
        "\n"
        "def main():\n"
        "    return render()\n"
    ),
    "cli.py": (
        "from pkg.app import main\n"
        "\n"
        "\n"
        "def run():\n"
        "    return main()\n"
    ),
    "lib/widget.dart": (
        "import 'package:flutter/material.dart';\n"
        "import 'helpers.dart';\n"
        "\n"
        "class MyWidget extends StatelessWidget {\n"
        "  void build() {\n"
        "  }\n"
        "}\n"
    ),
    # Filtered out by the github_sync conventions (skipped dir + binary).
    "node_modules/evil/index.py": "def hacked():\n    pass\n",
    "pkg/logo.png": "not really a png",
}


@pytest.fixture()
def mini_repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    for relative, content in FIXTURE_FILES.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    return root


@pytest.fixture()
def graph(mini_repo: Path):
    return parse_repo(mini_repo)


def _edge_set(graph, edge_type):
    return {
        (edge.source_qn, edge.target_qn) for edge in graph.edges_of(edge_type)
    }


def test_parse_python_nodes(graph):
    assert graph.node("CodeFile", "pkg/core.py") is not None
    assert graph.node("CodeModule", "pkg.core") is not None
    assert graph.node("Class", "pkg.core.LoudGreeter") is not None
    assert graph.node("Function", "pkg.core.LoudGreeter.greet") is not None
    assert graph.node("Function", "pkg.core.render") is not None
    assert graph.node("Function", "pkg.helpers.shout") is not None

    node = graph.node("Function", "pkg.helpers.shout")
    assert node.name == "shout"
    assert node.path == "pkg/helpers.py"
    assert node.line == 1
    assert node.language == "python"


def test_parse_skips_symlinked_file_escaping_root(tmp_path: Path):
    repo = tmp_path / "repo"
    repo.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "evil.py").write_text(
        "def leaked():\n    return 42\n", encoding="utf-8"
    )
    (repo / "evil_link.py").symlink_to(outside / "evil.py")
    (repo / "real.py").write_text("def ok():\n    return 1\n", encoding="utf-8")

    parsed = parse_repo(repo)
    paths = {node.path for node in parsed.nodes}
    assert paths == {"real.py"}
    assert parsed.node("Function", "evil_link.leaked") is None


def test_parse_skips_filtered_files(graph):
    paths = {node.path for node in graph.nodes}
    assert "node_modules/evil/index.py" not in paths
    assert "pkg/logo.png" not in paths
    assert graph.node("Function", "node_modules.evil.index.hacked") is None


def test_parse_defines_edges(graph):
    defines = _edge_set(graph, "DEFINES")
    assert ("pkg/core.py", "pkg.core") in defines
    assert ("pkg.core", "pkg.core.LoudGreeter") in defines
    assert ("pkg.core.LoudGreeter", "pkg.core.LoudGreeter.greet") in defines
    assert ("pkg.core", "pkg.core.render") in defines


def test_parse_imports_edges(graph):
    imports = _edge_set(graph, "IMPORTS")
    assert ("pkg.core", "pkg.helpers") in imports
    assert ("pkg.core", "pkg.base") in imports
    assert ("pkg.app", "pkg.core") in imports
    assert ("cli", "pkg.app") in imports


def test_parse_inherits_edges(graph):
    inherits = _edge_set(graph, "INHERITS")
    assert ("pkg.core.LoudGreeter", "pkg.base.BaseGreeter") in inherits


def test_parse_calls_edges_conservative(graph):
    calls = _edge_set(graph, "CALLS")
    # from-imported function, called from a method and a plain function
    assert ("pkg.core.LoudGreeter.greet", "pkg.helpers.shout") in calls
    assert ("pkg.core.render", "pkg.helpers.shout") in calls
    # transitive chain used by the impact tests
    assert ("pkg.app.main", "pkg.core.render") in calls
    assert ("cli.run", "pkg.app.main") in calls
    # self.method() call resolved within the enclosing class
    assert ("pkg.base.BaseGreeter.greet_loudly", "pkg.base.BaseGreeter.greet") in calls
    # unresolved/dynamic calls are under-claimed: str methods, print, etc.
    assert all("upper" not in target for _, target in calls)
    assert all(target != "print" for _, target in calls)


def test_parse_dart_file(graph):
    assert graph.node("CodeModule", "lib.widget") is not None
    widget = graph.node("Class", "lib.widget.MyWidget")
    assert widget is not None
    assert widget.language == "dart"
    assert widget.path == "lib/widget.dart"
    assert graph.node("Function", "lib.widget.MyWidget.build") is not None

    imports = _edge_set(graph, "IMPORTS")
    assert ("lib.widget", "package:flutter/material.dart") in imports
    assert ("lib.widget", "helpers.dart") in imports

    inherits = _edge_set(graph, "INHERITS")
    assert ("lib.widget.MyWidget", "StatelessWidget") in inherits

    # No CALLS edges are claimed for regex-parsed languages.
    assert all(
        not source.startswith("lib.widget")
        for source, _ in _edge_set(graph, "CALLS")
    )


class FakeNeo4jClient:
    """Records execute_write calls instead of touching a database."""

    def __init__(self):
        self.calls: list[tuple[str, dict]] = []

    def execute_write(self, query, parameters=None):
        self.calls.append((query, parameters or {}))
        return []

    def execute_read(self, query, parameters=None):  # pragma: no cover
        raise AssertionError("writer must not read")


def test_writer_is_parameterized_and_tenant_scoped(graph):
    client = FakeNeo4jClient()
    result = write_code_graph(client, graph, tenant_id="tenant-a")

    assert result == {
        "nodes_written": len(graph.nodes),
        "edges_written": len(graph.edges),
    }
    assert client.calls

    for query, params in client.calls:
        # Tenant and node identity travel as parameters, never inlined.
        assert "tenant-a" not in query
        assert "$" in query
        serialized = str(params)
        assert "tenant-a" in serialized

    node_writes = [c for c in client.calls if "MERGE (n:" in c[0]]
    assert any("MERGE (n:Class" in q for q, _ in node_writes)
    greet = [
        params
        for _, params in node_writes
        if params["properties"]["qualified_name"] == "pkg.core.LoudGreeter.greet"
    ]
    assert greet and greet[0]["properties"]["tenant_id"] == "tenant-a"
    # Code nodes carry no Qdrant point ID (structural nodes, not chunks).
    assert all(
        "qdrant" not in str(params["properties"]).lower()
        for _, params in node_writes
    )

    edge_writes = [c for c in client.calls if "MERGE (a)-[r:" in c[0]]
    assert any("MERGE (a)-[r:CALLS]" in q for q, _ in edge_writes)
    assert any("MERGE (a)-[r:IMPORTS]" in q for q, _ in edge_writes)
    assert any("MERGE (a)-[r:INHERITS]" in q for q, _ in edge_writes)
    for _, params in edge_writes:
        assert params["tenant_id"] == "tenant-a"
        assert params["from_key"].startswith("tenant-a::")
        assert params["to_key"].startswith("tenant-a::")


# ---------------------------------------------------------------------------
# Src-layout resolution + resolved:false placeholders (WP2)
# ---------------------------------------------------------------------------


@pytest.fixture()
def src_layout_repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    files = {
        "packages/veraxi-cli/src/veraxi/cli/main.py": (
            "from veraxi.cli.code_intel import run_xray_symbol\n"
            "\n\n"
            "def main():\n"
            "    return run_xray_symbol('x')\n"
        ),
        "packages/veraxi-cli/src/veraxi/cli/code_intel.py": (
            "def run_xray_symbol(name):\n"
            "    return name\n"
        ),
        "packages/veraxi-cli/src/veraxi/cli/__init__.py": "",
        "src/top.py": "def top():\n    return 1\n",
    }
    for relative, content in files.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    return root


def test_src_layout_module_resolution(src_layout_repo):
    parsed = parse_repo(src_layout_repo)
    module = parsed.node("CodeModule", "veraxi.cli.main")
    assert module is not None
    assert module.path == "packages/veraxi-cli/src/veraxi/cli/main.py"
    assert parsed.node("Function", "veraxi.cli.main.main") is not None
    # The cross-file import resolves to the real parsed node, so the
    # CALLS edge targets the real function, not a path="" stub.
    calls = _edge_set(parsed, "CALLS")
    assert ("veraxi.cli.main.main", "veraxi.cli.code_intel.run_xray_symbol") in calls
    assert parsed.node("CodeModule", "top") is not None


def test_placeholder_nodes_are_resolved_false(src_layout_repo):
    parsed = parse_repo(src_layout_repo)
    client = FakeNeo4jClient()
    write_code_graph(client, parsed, tenant_id="tenant-a")
    node_writes = [params for q, params in client.calls if "MERGE (n:" in q]
    by_qn = {
        params["properties"]["qualified_name"]: params["properties"]
        for params in node_writes
    }
    real = by_qn["veraxi.cli.main"]
    assert real["resolved"] is True
    assert real["path"] == "packages/veraxi-cli/src/veraxi/cli/main.py"


def test_unresolved_import_placeholder_marked(tmp_path: Path):
    root = tmp_path / "repo"
    root.mkdir()
    (root / "a.py").write_text(
        "import totally_external_pkg\n\n\ndef f():\n    return 1\n", encoding="utf-8"
    )
    parsed = parse_repo(root)
    client = FakeNeo4jClient()
    write_code_graph(client, parsed, tenant_id="tenant-a")
    node_writes = [params for q, params in client.calls if "MERGE (n:" in q]
    placeholders = [
        params["properties"]
        for params in node_writes
        if params["properties"]["qualified_name"] == "totally_external_pkg"
    ]
    assert placeholders and placeholders[0]["resolved"] is False
    assert placeholders[0]["path"] == ""


def test_parse_python_end_lines(graph):
    shout = graph.node("Function", "pkg.helpers.shout")
    assert shout.line == 1
    assert shout.end_line == 2
    assert shout.properties("tenant-a")["end_line"] == 2

    greeter = graph.node("Class", "pkg.base.BaseGreeter")
    assert greeter.line == 1
    assert greeter.end_line == 6
    greet = graph.node("Function", "pkg.base.BaseGreeter.greet")
    assert greet.end_line == 3

    # Nodes without a known extent leave end_line unset, and the
    # property is then absent from the persisted properties.
    module = graph.node("CodeModule", "pkg.helpers")
    assert module.end_line is None
    assert "end_line" not in module.properties("tenant-a")


def test_graph_from_payload_end_line_round_trip():
    from backend.ingestion.code_graph import graph_from_payload

    graph = graph_from_payload(
        nodes=[
            {"label": "Function", "name": "f", "qualified_name": "m.f",
             "path": "m.py", "line": 3, "end_line": 9, "language": "python"},
            {"label": "Function", "name": "g", "qualified_name": "m.g",
             "path": "m.py", "line": 12, "language": "python"},
        ],
        edges=[],
    )
    assert graph.nodes[0].end_line == 9
    assert graph.nodes[1].end_line is None


def test_graph_from_payload_whitelist_and_resolved():
    from backend.ingestion.code_graph import graph_from_payload

    graph = graph_from_payload(
        nodes=[
            {"label": "Function", "name": "f", "qualified_name": "m.f",
             "path": "m.py", "line": 3, "language": "python"},
            {"label": "Evil", "name": "x", "qualified_name": "m.x"},
            {"label": "CodeModule", "name": "ext", "qualified_name": "ext",
             "path": "", "line": 0, "language": "", "resolved": False},
        ],
        edges=[
            {"type": "CALLS", "source_qn": "m.f", "source_label": "Function",
             "target_qn": "ext", "target_label": "CodeModule"},
            {"type": "DROP", "source_qn": "m.f", "source_label": "Function",
             "target_qn": "ext", "target_label": "CodeModule"},
        ],
    )
    assert [n.qualified_name for n in graph.nodes] == ["m.f", "ext"]
    assert graph.nodes[1].resolved is False
    assert [e.type for e in graph.edges] == ["CALLS"]


def test_treesitter_parses_go_and_js_calls(tmp_path: Path):
    root = tmp_path / "poly"
    root.mkdir()
    (root / "server.go").write_text(
        'package main\nimport "fmt"\nfunc helper() {}\nfunc handler() { helper(); fmt.Println("ok") }\n',
        encoding="utf-8",
    )
    (root / "app.js").write_text(
        'import axios from "axios";\nfunction fetchUser() { return axios.get("/me"); }\nfunction run() { return fetchUser(); }\n',
        encoding="utf-8",
    )
    parsed = parse_repo(root)
    assert parsed.node("Function", "server.handler") is not None
    assert parsed.node("Function", "app.run") is not None
    imports = _edge_set(parsed, "IMPORTS")
    assert ("server", "fmt") in imports
    assert ("app", "axios") in imports
    calls = _edge_set(parsed, "CALLS")
    assert ("server.handler", "server.helper") in calls
    assert ("app.run", "app.fetchUser") in calls


# ---------------------------------------------------------------------------
# SCIP ingestion (scip print --json, stdlib-only)
# ---------------------------------------------------------------------------

_SHOUT_SYMBOL = "scip-python python demo 1.0 `pkg/helpers.py`shout()."
_GREETER_SYMBOL = "scip-python python demo 1.0 `pkg/core.py`Greeter#"
_GREET_SYMBOL = "scip-python python demo 1.0 `pkg/core.py`Greeter#greet()."
_PRINT_SYMBOL = "scip-python python stdlib 1.0 `builtins`print()."

SCIP_FIXTURE = {
    "metadata": {"version": "0.3.0", "tool_info": {"name": "scip-python"}},
    "documents": [
        {
            "relative_path": "pkg/helpers.py",
            "language": "python",
            "symbols": [
                {
                    "symbol": _SHOUT_SYMBOL,
                    "kind": "Function",
                    "display_name": "shout",
                    "signature_documentation": {"language": "python", "text": "def shout(text)"},
                    "relationships": [],
                }
            ],
            "occurrences": [
                {
                    "range": [0, 4, 9],
                    "symbol": _SHOUT_SYMBOL,
                    "symbol_roles": 1,
                    "enclosing_range": [0, 0, 1, 20],
                }
            ],
        },
        {
            "relative_path": "pkg/core.py",
            "language": "python",
            "symbols": [
                {
                    "symbol": _GREETER_SYMBOL,
                    "kind": "Class",
                    "display_name": "Greeter",
                    "relationships": [],
                },
                {
                    "symbol": _GREET_SYMBOL,
                    "kind": "Method",
                    "display_name": "greet",
                    "relationships": [],
                },
            ],
            "occurrences": [
                {
                    "range": [0, 6, 13],
                    "symbol": _GREETER_SYMBOL,
                    "symbol_roles": 1,
                    "enclosing_range": [0, 0, 3, 20],
                },
                {
                    "range": [1, 8, 13],
                    "symbol": _GREET_SYMBOL,
                    "symbol_roles": 1,
                    "enclosing_range": [1, 4, 2, 30],
                },
                # Cross-file reference, enclosed by greet (via its own
                # enclosing_range naming greet's definition span).
                {
                    "range": [2, 15, 20],
                    "symbol": _SHOUT_SYMBOL,
                    "symbol_roles": 8,
                    "enclosing_range": [1, 4, 2, 30],
                },
                # Duplicate reference (range-only containment): deduped.
                {
                    "range": [2, 22, 27],
                    "symbol": _SHOUT_SYMBOL,
                    "symbol_roles": 8,
                },
                # Referenced but not defined in this index: no edge.
                {
                    "range": [2, 8, 13],
                    "symbol": _PRINT_SYMBOL,
                    "symbol_roles": 8,
                },
            ],
        },
    ],
}


@pytest.fixture()
def scip_graph():
    from backend.ingestion.scip_ingest import parse_scip_payload

    return parse_scip_payload(SCIP_FIXTURE)


def test_scip_documents_become_nodes(scip_graph):
    shout_qn = "pkg/helpers.py::shout()."
    assert scip_graph.node("CodeFile", "pkg/helpers.py") is not None
    assert scip_graph.node("CodeFile", "pkg/core.py") is not None
    shout = scip_graph.node("Function", shout_qn)
    assert shout is not None
    assert shout.name == "shout"
    assert shout.path == "pkg/helpers.py"
    assert shout.line == 1
    assert shout.resolved is True
    greeter = scip_graph.node("Class", "pkg/core.py::Greeter#")
    assert greeter is not None and greeter.name == "Greeter"
    greet = scip_graph.node("Function", "pkg/core.py::Greeter#greet().")
    assert greet is not None and greet.name == "greet"
    # No node is created for the undefined external symbol.
    assert all("builtins" not in n.qualified_name for n in scip_graph.nodes)
    assert len(scip_graph.nodes) == 5


def test_scip_defines_edges(scip_graph):
    defines = _edge_set(scip_graph, "DEFINES")
    shout_qn = "pkg/helpers.py::shout()."
    greeter_qn = "pkg/core.py::Greeter#"
    greet_qn = "pkg/core.py::Greeter#greet()."
    assert defines == {
        ("pkg/helpers.py", shout_qn),
        ("pkg/core.py", greeter_qn),
        ("pkg/core.py", greet_qn),
    }


def test_scip_cross_file_references_edge_deduped(scip_graph):
    references = _edge_set(scip_graph, "REFERENCES")
    greet_qn = "pkg/core.py::Greeter#greet()."
    shout_qn = "pkg/helpers.py::shout()."
    assert references == {(greet_qn, shout_qn)}


def test_scip_definition_occurrences_produce_no_self_reference(scip_graph):
    for edge in scip_graph.edges_of("REFERENCES"):
        assert edge.source_qn != edge.target_qn
    # The definition occurrence of shout in helpers.py is not a reference.
    assert all(
        source != "pkg/helpers.py" or "shout" not in target
        for source, target in _edge_set(scip_graph, "REFERENCES")
    )


def test_scip_write_reuses_code_graph_writer(scip_graph):
    client = FakeNeo4jClient()
    from backend.ingestion.scip_ingest import write_scip_graph

    result = write_scip_graph(client, SCIP_FIXTURE, tenant_id="tenant-a")
    assert result == {
        "nodes_written": len(scip_graph.nodes),
        "edges_written": len(scip_graph.edges),
    }
    edge_writes = [c for c in client.calls if "MERGE (a)-[r:" in c[0]]
    assert any("MERGE (a)-[r:REFERENCES]" in q for q, _ in edge_writes)
    # No placeholder node was written for the undefined print symbol.
    node_writes = [params for q, params in client.calls if "MERGE (n:" in q]
    assert all(
        "builtins" not in str(params["properties"]["qualified_name"])
        for params in node_writes
    )


def test_scip_oversize_raises(monkeypatch):
    from backend.ingestion import scip_ingest

    monkeypatch.setattr(scip_ingest, "MAX_INGEST_NODES", 2)
    with pytest.raises(ValueError):
        scip_ingest.parse_scip_payload(SCIP_FIXTURE)


def test_scip_malformed_payload_raises():
    from backend.ingestion.scip_ingest import parse_scip_payload

    with pytest.raises(ValueError):
        parse_scip_payload({"no_documents": []})
    with pytest.raises(ValueError):
        parse_scip_payload([])  # type: ignore[arg-type]


def test_treesitter_parses_cpp_csharp_ruby_kotlin(tmp_path: Path):
    root = tmp_path / "more_langs"
    root.mkdir()
    (root / "engine.cpp").write_text(
        '#include "engine.hpp"\nclass Engine {};\nint run() { return 0; }\n',
        encoding="utf-8",
    )
    (root / "Service.cs").write_text(
        "using System;\nclass Service { void Handle() {} }\n",
        encoding="utf-8",
    )
    (root / "app.rb").write_text(
        "class Worker\n  def perform\n  end\nend\n",
        encoding="utf-8",
    )
    (root / "Main.kt").write_text(
        "import kotlin.io.println\nclass App { fun start() {} }\n",
        encoding="utf-8",
    )
    parsed = parse_repo(root)
    assert parsed.node("Class", "engine.Engine") is not None
    assert parsed.node("Class", "Service.Service") is not None
    assert parsed.node("Function", "Service.Service.Handle") is not None
    assert parsed.node("Class", "app.Worker") is not None
    assert parsed.node("Function", "app.Worker.perform") is not None
    assert parsed.node("Class", "Main.App") is not None
    assert parsed.node("Function", "Main.App.start") is not None
