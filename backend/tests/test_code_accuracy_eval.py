"""Tests for the Phase 16 code-accuracy baseline fixture (ADR-0007).

The fixture itself is the measurement instrument: these tests pin
its shape (case count, coverage of the required tricky patterns) and
assert the evaluation runs deterministically through the real parser.
Accuracy thresholds live in the Phase 1 regression tests in
``test_code_graph.py``; this file only guards the fixture/evaluator.
"""

from backend.evaluation.code_accuracy import CASES, evaluate_cases, predicted_calls

REQUIRED_CASE_IDS = {
    "assignment-alias-same-file",
    "init-reexport-plain",
    "init-reexport-renamed-dogfood",
    "from-import-as-private-name",
    "function-local-import",
    "same-name-collision-cross-module",
}


def test_fixture_has_about_fifteen_cases():
    assert 14 <= len(CASES) <= 18


def test_fixture_covers_required_patterns():
    assert REQUIRED_CASE_IDS <= {case.id for case in CASES}


def test_fixture_case_ids_are_unique():
    ids = [case.id for case in CASES]
    assert len(ids) == len(set(ids))


def test_evaluate_cases_reports_precision_and_recall():
    result = evaluate_cases()
    assert 0.0 <= result["precision"] <= 1.0
    assert 0.0 <= result["recall"] <= 1.0
    assert len(result["cases"]) == len(CASES)
    total_expected = sum(len(case.expected_calls) for case in CASES)
    assert result["true_positives"] + result["false_negatives"] == total_expected


def test_predicted_calls_for_direct_case():
    case = next(c for c in CASES if c.id == "direct-same-file")
    assert predicted_calls(case) == {("mod.caller", "mod.target")}
