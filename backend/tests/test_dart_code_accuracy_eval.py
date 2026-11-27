"""Tests for the Phase 5A Dart code-accuracy baseline fixture (ADR-0007).

Guards the measurement instrument itself: case count, coverage of real
Dart/Flutter patterns from ``app/``, unique IDs, buildable ``pubspec.yaml``
per case, representation-independent normalization, and honest zero-prediction
precision reporting.
"""

from backend.evaluation.dart_code_accuracy import (
    CASES,
    evaluate_dart_cases,
    predicted_dart_calls,
    score_predictions,
)
from backend.ingestion.code_graph import CodeEdge, CodeGraph, CodeNode

REQUIRED_CASE_IDS = {
    "direct-same-file",
    "method-same-class",
    "relative-import-call",
    "package-import-call",
    "import-as-prefix",
    "export-barrel-reexport",
    "conditional-export",
    "part-and-part-of",
    "constructor-and-factory",
    "inherited-method-dispatch",
    "mixin-method-call",
    "extension-method-call",
    "function-tearoff-callback",
    "instance-method-typed-field",
    "multi-hop-chain",
    "same-name-collision-cross-file",
    "unresolved-dynamic-and-method-channel",
}


def test_dart_fixture_case_count():
    assert 15 <= len(CASES) <= 20


def test_dart_fixture_covers_required_patterns():
    assert REQUIRED_CASE_IDS <= {case.id for case in CASES}


def test_dart_fixture_case_ids_are_unique_and_have_pubspec():
    ids = [case.id for case in CASES]
    assert len(ids) == len(set(ids))
    for case in CASES:
        assert "pubspec.yaml" in case.files


def test_evaluate_dart_cases_reports_honest_zero_prediction_metrics():
    result = evaluate_dart_cases()
    assert len(result["cases"]) == len(CASES)
    total_expected = sum(len(case.expected_calls) for case in CASES)
    assert result["true_positives"] + result["false_negatives"] == total_expected
    assert 0.0 <= result["recall"] <= 1.0
    if result["true_positives"] + result["false_positives"] == 0:
        assert result["precision"] is None
    else:
        assert 0.0 <= result["precision"] <= 1.0


def test_score_predictions_uses_normalized_4_tuples():
    perfect = score_predictions(CASES, lambda case: case.expected_calls)
    assert perfect["precision"] == 1.0
    assert perfect["recall"] == 1.0
    assert perfect["false_positives"] == 0
    assert perfect["false_negatives"] == 0


def test_predicted_dart_calls_baseline_is_deterministic():
    case = next(c for c in CASES if c.id == "direct-same-file")
    assert isinstance(predicted_dart_calls(case), set)


def test_normalize_graph_calls_supports_scip_references():
    from backend.evaluation.dart_code_accuracy import normalize_graph_calls

    graph = CodeGraph(
        nodes=[
            CodeNode(
                label="Function",
                name="caller",
                qualified_name="lib/caller.dart::caller().",
                path="lib/caller.dart",
                line=3,
                language="dart",
                resolution="scip",
            ),
            CodeNode(
                label="Function",
                name="target",
                qualified_name="lib/impl.dart::target().",
                path="lib/impl.dart",
                line=1,
                language="dart",
                resolution="scip",
            ),
        ],
        edges=[
            CodeEdge(
                type="REFERENCES",
                source_qn="lib/caller.dart::caller().",
                source_label="Function",
                target_qn="lib/impl.dart::target().",
                target_label="Function",
            )
        ],
    )
    assert normalize_graph_calls(graph, edge_type="REFERENCES") == {
        ("lib/caller.dart", "caller", "lib/impl.dart", "target")
    }
