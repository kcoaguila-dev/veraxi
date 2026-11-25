"""Phase 4 (ADR-0007) tests: real SCIP output parsing, resolution
provenance, SCIP-wins write semantics, and impact confidence.

The camelCase fixture is the Phase 0/1 SCIP fixture mechanically
rewritten to the key style real ``scip print --json`` emits
(protobuf-JSON camelCase) — the Phase 3 spike found the shipped
parser silently produced an empty graph from real indexes.
"""

from __future__ import annotations

import copy

from backend.ingestion.code_graph import CodeGraph, CodeNode, parse_repo
from backend.ingestion.scip_ingest import parse_scip_payload, write_scip_graph
from backend.retrieval.code_queries import impact_analysis
from backend.tests.test_code_graph import SCIP_FIXTURE, FakeNeo4jClient

_KEYMAP = {
    "relative_path": "relativePath",
    "symbol_roles": "symbolRoles",
    "enclosing_range": "enclosingRange",
    "display_name": "displayName",
    "signature_documentation": "signatureDocumentation",
    "project_root": "projectRoot",
    "tool_info": "toolInfo",
}


def _camelize(value):
    if isinstance(value, dict):
        return {_KEYMAP.get(k, k): _camelize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_camelize(v) for v in value]
    return value


class TestRealScipOutputParsing:
    def test_camelcase_payload_parses_like_snake_case(self):
        snake = parse_scip_payload(copy.deepcopy(SCIP_FIXTURE))
        camel = parse_scip_payload(_camelize(copy.deepcopy(SCIP_FIXTURE)))
        assert {(n.label, n.qualified_name) for n in camel.nodes} == {
            (n.label, n.qualified_name) for n in snake.nodes
        }
        assert {(e.type, e.source_qn, e.target_qn) for e in camel.edges} == {
            (e.type, e.source_qn, e.target_qn) for e in snake.edges
        }
        assert len(camel.nodes) == 5  # the pre-fix parser produced 0 here

    def test_verbatim_real_document_parses(self):
        # Verbatim (trimmed) document from a real scip-python 0.6.8 /
        # scip print v0.4.0 run over pallets/itsdangerous.
        payload = {
            "metadata": {
                "toolInfo": {"name": "scip-python", "version": "0.6.8"},
                "projectRoot": "file:///tmp/scip-ext/itsdangerous",
                "textDocumentEncoding": "UTF8",
            },
            "documents": [
                {
                    "relativePath": "tests/test_itsdangerous/__init__.py",
                    "occurrences": [
                        {
                            "range": [0, 0, 0],
                            "symbol": "scip-python python itsdangerous 672971d66a2ef9f85151e53283113f33d642dabd `tests.test_itsdangerous`/__init__:",
                            "symbolRoles": 1,
                        }
                    ],
                    "symbols": [
                        {
                            "symbol": "scip-python python itsdangerous 672971d66a2ef9f85151e53283113f33d642dabd `tests.test_itsdangerous`/__init__:",
                            "documentation": ["(module) tests.test_itsdangerous"],
                        }
                    ],
                }
            ],
        }
        graph = parse_scip_payload(payload)
        assert graph.node("CodeFile", "tests/test_itsdangerous/__init__.py") is not None


class TestResolutionProvenance:
    def test_scip_nodes_carry_scip_resolution(self):
        graph = parse_scip_payload(copy.deepcopy(SCIP_FIXTURE))
        assert graph.nodes
        assert all(node.resolution == "scip" for node in graph.nodes)
        props = graph.nodes[0].properties("tenant-a")
        assert props["resolution"] == "scip"

    def test_ast_nodes_carry_heuristic_resolution(self, tmp_path):
        (tmp_path / "mod.py").write_text(
            "def target():\n    pass\n\n\ndef caller():\n    target()\n",
            encoding="utf-8",
        )
        graph = parse_repo(tmp_path)
        assert graph.nodes
        assert all(node.resolution == "heuristic" for node in graph.nodes)
        assert graph.nodes[0].properties("t")["resolution"] == "heuristic"

    def test_graph_from_payload_resolution_passthrough(self):
        from backend.ingestion.code_graph import graph_from_payload

        graph = graph_from_payload(
            [
                {
                    "label": "Function",
                    "qualified_name": "m.f",
                    "name": "f",
                    "path": "m.py",
                    "line": 1,
                    "resolution": "scip",
                },
                {
                    "label": "Function",
                    "qualified_name": "m.g",
                    "name": "g",
                    "path": "m.py",
                    "line": 2,
                    "resolution": "bogus",
                },
            ],
            [],
            repo_key="r",
        )
        by_qn = {n.qualified_name: n for n in graph.nodes}
        assert by_qn["m.f"].resolution == "scip"
        assert by_qn["m.g"].resolution == "heuristic"  # invalid values fail safe


class TestScipWinsWrite:
    def test_write_deletes_covered_paths_before_writing(self):
        client = FakeNeo4jClient()
        result = write_scip_graph(client, copy.deepcopy(SCIP_FIXTURE), tenant_id="tenant-a")
        assert result["nodes_written"] == 5
        queries = [q for q, _ in client.calls]
        delete_idx = next(
            i for i, q in enumerate(queries) if "DETACH DELETE" in q
        )
        first_node_idx = next(i for i, q in enumerate(queries) if "MERGE (n:" in q)
        assert delete_idx < first_node_idx
        delete_params = client.calls[delete_idx][1]
        assert sorted(delete_params["paths"]) == ["pkg/core.py", "pkg/helpers.py"]
        assert delete_params["tenant_id"] == "tenant-a"

    def test_written_node_properties_carry_resolution(self):
        client = FakeNeo4jClient()
        write_scip_graph(client, copy.deepcopy(SCIP_FIXTURE), tenant_id="tenant-a")
        node_props = [
            params["properties"]
            for q, params in client.calls
            if "MERGE (n:" in q and "properties" in (params or {})
        ]
        assert node_props
        assert all(p.get("resolution") == "scip" for p in node_props)


class _FakeCodeClient:
    """Minimal CodeGraphClient fake for impact_analysis."""

    def __init__(self, roots, edges_by_target=None):
        self._roots = roots
        self._edges = edges_by_target or {}

    def find_symbols(self, tenant_id, *, qualified_name=None, name=None, repo_key=None):
        return list(self._roots)

    def incoming_edges(self, tenant_id, target_qns, repo_key=None):
        rows = []
        for qn in target_qns:
            rows.extend(self._edges.get(qn, []))
        return rows

    def index_meta(self, tenant_id, repo_key=None):
        return None

    def index_metas(self, tenant_id):
        return []


def _root(qn="pkg.target", resolution="heuristic"):
    return {
        "qualified_name": qn,
        "name": "target",
        "label": "Function",
        "path": "pkg/impl.py",
        "line": 1,
        "end_line": 2,
        "language": "python",
        "resolved": True,
        "repo_key": "",
        "resolution": resolution,
    }


class TestImpactConfidence:
    def test_no_impact_heuristic_is_low_confidence_with_note(self):
        client = _FakeCodeClient([_root()])
        result = impact_analysis("target", client=client)
        assert result["found"] is True
        assert result["impacted"] == []
        assert result["resolution"] == "heuristic"
        assert result["confidence"] == "low"
        assert "unproven" in result["confidence_note"]

    def test_no_impact_scip_is_high_confidence_no_note(self):
        client = _FakeCodeClient([_root(resolution="scip")])
        result = impact_analysis("target", client=client)
        assert result["impacted"] == []
        assert result["resolution"] == "scip"
        assert result["confidence"] == "high"
        assert "confidence_note" not in result

    def test_mixed_resolution_is_medium(self):
        edges = {
            "pkg.target": [
                {
                    "source_qn": "pkg.caller",
                    "source_name": "caller",
                    "source_label": "Function",
                    "source_path": "pkg/caller.py",
                    "source_line": 1,
                    "source_end_line": 2,
                    "source_repo_key": "",
                    "source_resolution": "scip",
                    "edge_type": "CALLS",
                    "target_qn": "pkg.target",
                }
            ]
        }
        client = _FakeCodeClient([_root()], edges)
        result = impact_analysis("target", client=client)
        assert len(result["impacted"]) == 1
        assert result["resolution"] == "mixed"
        assert result["confidence"] == "medium"

    def test_not_found_is_low_confidence(self):
        client = _FakeCodeClient([])
        result = impact_analysis("missing", client=client)
        assert result["found"] is False
        assert result["confidence"] == "low"
        assert result["resolution"] == "unknown"

    def test_existing_keys_unchanged(self):
        client = _FakeCodeClient([_root()])
        result = impact_analysis("target", client=client)
        for key in ("symbol", "found", "roots", "max_depth", "impacted", "freshness"):
            assert key in result


def test_code_graph_still_pure():
    # Guard: CodeGraph/CodeNode defaults stay dependency-free values.
    graph = CodeGraph(nodes=[CodeNode("Function", "f", "m.f", "m.py", 1, "python")])
    assert graph.nodes[0].resolution == "heuristic"
