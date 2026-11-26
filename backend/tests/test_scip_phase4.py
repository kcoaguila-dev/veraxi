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


# ---------------------------------------------------------------------------
# Phase 4 prep: architectural-symbol filter + canonical repo_key partition.
#
# What these tests prove / do not prove: FakeNeo4jClient only *records*
# write calls, so replacement is proven at the write-protocol level —
# a DETACH DELETE scoped to (tenant, repo_key, covered paths) is issued
# before the SCIP node writes, and uncovered paths are absent from its
# parameters, which is exactly the mechanism write_code_graph /
# _delete_nodes_for_paths use against a real database. They do NOT
# prove live Neo4j behaviour; that smoke test remains a human gate.
# ---------------------------------------------------------------------------

_MIXED_PAYLOAD = {
    "metadata": {"project_root": "demo-repo"},
    "documents": [
        {
            "relative_path": "pkg/mod.py",
            "language": "python",
            "symbols": [
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#", "kind": "Class", "display_name": "Greeter"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#greet().", "kind": "Method", "display_name": "greet"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`helper().", "kind": "Function", "display_name": "helper"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`MAX_RETRIES.", "kind": "Constant", "display_name": "MAX_RETRIES"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`count.", "kind": "Variable", "display_name": "count"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#field.", "kind": "Field", "display_name": "field"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#greet().(text)", "kind": "Parameter", "display_name": "text"},
                {"symbol": "local 0", "kind": "Variable", "display_name": "tmp"},
            ],
            "occurrences": [
                {"range": [0, 6, 13], "symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#", "symbol_roles": 1, "enclosing_range": [0, 0, 5, 20]},
                {"range": [1, 8, 13], "symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#greet().", "symbol_roles": 1, "enclosing_range": [1, 4, 3, 30]},
                {"range": [2, 15, 21], "symbol": "scip-python python demo 1.0 `pkg/mod.py`helper().", "symbol_roles": 8, "enclosing_range": [1, 4, 3, 30]},
                {"range": [6, 4, 10], "symbol": "scip-python python demo 1.0 `pkg/mod.py`helper().", "symbol_roles": 1, "enclosing_range": [6, 0, 7, 20]},
                {"range": [8, 0, 11], "symbol": "scip-python python demo 1.0 `pkg/mod.py`MAX_RETRIES.", "symbol_roles": 1},
                {"range": [9, 0, 5], "symbol": "scip-python python demo 1.0 `pkg/mod.py`count.", "symbol_roles": 1},
                {"range": [1, 12, 17], "symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#field.", "symbol_roles": 1},
                {"range": [1, 20, 24], "symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#greet().(text)", "symbol_roles": 1},
                {"range": [2, 8, 11], "symbol": "local 0", "symbol_roles": 1},
                {"range": [2, 8, 11], "symbol": "local 0", "symbol_roles": 8, "enclosing_range": [1, 4, 3, 30]},
            ],
        }
    ],
}


class TestArchitecturalFilter:
    def test_mixed_payload_counts_before_style_symbols_filtered(self):
        # Synthetic payload (see module-level _MIXED_PAYLOAD): without
        # the filter this exact payload parses to 9 nodes / 10 edges
        # (measured pre-filter); with it, only architectural symbols
        # remain: CodeFile + Class + Method + Function + Constant.
        graph = parse_scip_payload(copy.deepcopy(_MIXED_PAYLOAD))
        assert len(graph.nodes) == 5
        assert len(graph.edges) == 5

    def test_filter_keeps_architectural_and_drops_the_rest(self):
        graph = parse_scip_payload(copy.deepcopy(_MIXED_PAYLOAD))
        qns = {n.qualified_name for n in graph.nodes}
        assert "pkg/mod.py::Greeter#" in qns
        assert "pkg/mod.py::Greeter#greet()." in qns
        assert "pkg/mod.py::helper()." in qns
        assert "pkg/mod.py::MAX_RETRIES." in qns  # module constant stays
        assert not any("count" in q or "field" in q or "(text)" in q or "local" in q for q in qns)

    def test_reference_to_filtered_symbol_produces_no_edge(self):
        graph = parse_scip_payload(copy.deepcopy(_MIXED_PAYLOAD))
        refs = {(e.source_qn, e.target_qn) for e in graph.edges if e.type == "REFERENCES"}
        assert refs == {("pkg/mod.py::Greeter#greet().", "pkg/mod.py::helper().")}


# Same shape as _MIXED_PAYLOAD but as a real indexer emits it: kinds
# are enum ints, not strings (``scip print --json``), so the
# string-kind filter cannot see the parameter at all. Also carries a
# parameter that exists only as a definition occurrence (never listed
# in symbols[]) and a type parameter. Measured motivation: on real
# scip-python 0.6.8 output the pre-fix filter let parameters through
# and node counts landed at ~1.01x the payload symbol count.
_REAL_SHAPE_PAYLOAD = {
    "metadata": {"project_root": "demo-repo"},
    "documents": [
        {
            "relative_path": "pkg/mod.py",
            "language": "python",
            "symbols": [
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#", "kind": 9, "display_name": "Greeter"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#greet().", "kind": 30, "display_name": "greet"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`helper().", "kind": 22, "display_name": "helper"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`MAX_RETRIES.", "kind": 10, "display_name": "MAX_RETRIES"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#greet().(text)", "kind": 38, "display_name": "text"},
                {"symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#[T]", "kind": 54, "display_name": "T"},
            ],
            "occurrences": [
                {"range": [0, 6, 13], "symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#", "symbol_roles": 1, "enclosing_range": [0, 0, 5, 20]},
                {"range": [1, 8, 13], "symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#greet().", "symbol_roles": 1, "enclosing_range": [1, 4, 3, 30]},
                {"range": [2, 15, 21], "symbol": "scip-python python demo 1.0 `pkg/mod.py`helper().", "symbol_roles": 8, "enclosing_range": [1, 4, 3, 30]},
                {"range": [6, 4, 10], "symbol": "scip-python python demo 1.0 `pkg/mod.py`helper().", "symbol_roles": 1, "enclosing_range": [6, 0, 7, 20]},
                {"range": [8, 0, 11], "symbol": "scip-python python demo 1.0 `pkg/mod.py`MAX_RETRIES.", "symbol_roles": 1},
                {"range": [1, 20, 24], "symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#greet().(text)", "symbol_roles": 1},
                {"range": [2, 22, 26], "symbol": "scip-python python demo 1.0 `pkg/mod.py`Greeter#greet().(text)", "symbol_roles": 8, "enclosing_range": [1, 4, 3, 30]},
                {"range": [6, 11, 16], "symbol": "scip-python python demo 1.0 `pkg/mod.py`helper().(shout)", "symbol_roles": 1},
            ],
        }
    ],
}


class TestArchitecturalFilterRealPayloadShapes:
    def test_enum_int_kinds_still_filter_parameters(self):
        graph = parse_scip_payload(copy.deepcopy(_REAL_SHAPE_PAYLOAD))
        # CodeFile + Class + Method + Function + Constant; the
        # parameter, the type parameter and the occurrence-only
        # parameter are all filtered despite their non-string kinds.
        assert len(graph.nodes) == 5
        assert len(graph.edges) == 5

    def test_enum_int_kinds_keep_architectural_symbols(self):
        graph = parse_scip_payload(copy.deepcopy(_REAL_SHAPE_PAYLOAD))
        qns = {n.qualified_name for n in graph.nodes}
        assert "pkg/mod.py::Greeter#" in qns
        assert "pkg/mod.py::Greeter#greet()." in qns
        assert "pkg/mod.py::helper()." in qns
        assert "pkg/mod.py::MAX_RETRIES." in qns
        assert not any("(text)" in q or "(shout)" in q or "[T]" in q for q in qns)

    def test_reference_to_enum_kind_parameter_produces_no_edge(self):
        graph = parse_scip_payload(copy.deepcopy(_REAL_SHAPE_PAYLOAD))
        refs = {(e.source_qn, e.target_qn) for e in graph.edges if e.type == "REFERENCES"}
        assert refs == {("pkg/mod.py::Greeter#greet().", "pkg/mod.py::helper().")}


class TestRepoKeyPartition:
    def test_explicit_repo_key_wins_over_project_root(self):
        client = FakeNeo4jClient()
        write_scip_graph(
            client, copy.deepcopy(SCIP_FIXTURE), tenant_id="tenant-a", repo_key="owner/repo"
        )
        delete_params = next(p for q, p in client.calls if "DETACH DELETE" in q)
        assert delete_params["repo_key"] == "owner/repo"
        node_props = [
            params["properties"]
            for q, params in client.calls
            if "MERGE (n:" in q and "properties" in (params or {})
        ]
        assert node_props
        assert all(p.get("repo_key") == "owner/repo" for p in node_props)

    def test_repo_key_falls_back_to_scip_upload_when_omitted(self):
        # SCIP_FIXTURE carries no metadata.project_root.
        client = FakeNeo4jClient()
        write_scip_graph(client, copy.deepcopy(SCIP_FIXTURE), tenant_id="tenant-a")
        delete_params = next(p for q, p in client.calls if "DETACH DELETE" in q)
        assert delete_params["repo_key"] == "scip-upload"

    def test_ast_then_scip_same_repo_key_replaces_covered_not_uncovered(self):
        from backend.ingestion.code_graph import graph_from_payload, write_code_graph

        client = FakeNeo4jClient()
        ast_graph = graph_from_payload(
            [
                {"label": "Class", "qualified_name": "pkg.core.Greeter", "name": "Greeter", "path": "pkg/core.py", "line": 1},
                {"label": "Function", "qualified_name": "pkg.helpers.shout", "name": "shout", "path": "pkg/helpers.py", "line": 1},
                {"label": "Function", "qualified_name": "pkg.other.other_func", "name": "other_func", "path": "pkg/other.py", "line": 1},
            ],
            [],
            repo_key="owner/repo",
        )
        write_code_graph(client, ast_graph, tenant_id="tenant-a")
        ast_call_count = len(client.calls)

        result = write_scip_graph(
            client, copy.deepcopy(SCIP_FIXTURE), tenant_id="tenant-a", repo_key="owner/repo"
        )
        scip_calls = client.calls[ast_call_count:]
        deletes = [(i, p) for i, (q, p) in enumerate(scip_calls) if "DETACH DELETE" in q]
        assert len(deletes) == 1
        delete_idx, delete_params = deletes[0]
        # Covered AST files are in the delete scope, under the SAME
        # repo_key the AST ingest used; the uncovered file is not, so
        # its heuristic nodes survive the SCIP write.
        assert sorted(delete_params["paths"]) == ["pkg/core.py", "pkg/helpers.py"]
        assert "pkg/other.py" not in delete_params["paths"]
        assert delete_params["repo_key"] == "owner/repo"
        assert delete_params["tenant_id"] == "tenant-a"
        first_node_idx = next(
            i for i, (q, _) in enumerate(scip_calls) if "MERGE (n:" in q
        )
        assert delete_idx < first_node_idx
        # SCIP nodes are written exactly once each (not doubled).
        scip_node_keys = [
            (params["properties"].get("label", q), params["properties"]["qualified_name"])
            for q, params in scip_calls
            if "MERGE (n:" in q and "properties" in (params or {})
        ]
        assert len(scip_node_keys) == result["nodes_written"] == 5
        assert len({qn for _, qn in scip_node_keys}) == 5

    def test_impact_resolution_follows_partition_provenance(self):
        # Covered symbol: its stored node comes from the SCIP parse, so
        # impact_analysis reports scip/high. Uncovered symbol: only the
        # heuristic AST node exists, so the verdict stays low-confidence.
        scip_graph = parse_scip_payload(copy.deepcopy(SCIP_FIXTURE))
        covered = next(n for n in scip_graph.nodes if n.name == "greet")
        assert covered.resolution == "scip"
        scip_result = impact_analysis(
            "greet", client=_FakeCodeClient([_root(covered.qualified_name, resolution=covered.resolution)])
        )
        assert scip_result["resolution"] == "scip"
        assert scip_result["confidence"] == "high"

        ast_result = impact_analysis(
            "target", client=_FakeCodeClient([_root(resolution="heuristic")])
        )
        assert ast_result["resolution"] == "heuristic"
        assert ast_result["confidence"] == "low"

    def test_enum_int_and_omitted_kind_classes_labeled_class(self):
        payload = {
            "metadata": {"project_root": "repo"},
            "documents": [
                {
                    "relative_path": "pkg/models.py",
                    "language": "python",
                    "symbols": [
                        {
                            "symbol": "scip-python python pkg 0.1.0 `pkg.models`/Widget#",
                            "kind": 7,
                            "display_name": "Widget",
                        },
                        {
                            "symbol": "scip-python python pkg 0.1.0 `pkg.models`/build().",
                            "kind": 17,
                            "display_name": "build",
                        },
                    ],
                    "occurrences": [
                        {
                            "symbol": "scip-python python pkg 0.1.0 `pkg.models`/Widget#",
                            "range": [0, 6, 0, 12],
                            "symbol_roles": 1,
                        },
                        {
                            "symbol": "scip-python python pkg 0.1.0 `pkg.models`/Gadget#",
                            "range": [4, 6, 4, 12],
                            "symbol_roles": 1,
                        },
                        {
                            "symbol": "scip-python python pkg 0.1.0 `pkg.models`/build().",
                            "range": [8, 4, 8, 9],
                            "symbol_roles": 1,
                        },
                    ],
                }
            ],
        }
        graph = parse_scip_payload(payload)
        labels = {n.name: n.label for n in graph.nodes}
        assert labels["Widget"] == "Class"
        assert labels["Gadget"] == "Class"
        assert labels["build"] == "Function"
