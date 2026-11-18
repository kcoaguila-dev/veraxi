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
