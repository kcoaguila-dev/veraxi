"""Tests for the typed evidence-eval dataset, ablation runner and report.

Fully offline: a fake retriever returns fixed rankings per configuration.
"""

import json
from pathlib import Path

import pytest

from backend.evaluation.ablation import (
    CONFIGURATIONS,
    RetrievalResult,
    hit_at_k,
    recall_at_k,
    run_ablation,
)
from backend.evaluation.report import render_markdown, results_to_dict
from backend.evaluation.typed_dataset import (
    QUERY_TYPES,
    DatasetValidationError,
    load_dataset,
    parse_dataset,
)

SEED_DATASET_PATH = (
    Path(__file__).resolve().parents[1] / "evaluation" / "seed_dataset.json"
)


def _case(**overrides):
    case = {
        "id": "c1",
        "query_type": "lookup",
        "query": "What is X?",
        "relevant_doc_ids": ["doc-a"],
    }
    case.update(overrides)
    return case


# --- Dataset validation ---------------------------------------------------


def test_seed_dataset_loads_with_at_least_three_cases_per_type():
    dataset = load_dataset(SEED_DATASET_PATH)
    assert len(dataset.cases) >= 9
    for query_type in QUERY_TYPES:
        assert len(dataset.by_type(query_type)) >= 3


def test_valid_dataset_loads_and_parses_optional_fields():
    dataset = parse_dataset(
        {
            "name": "mini",
            "cases": [
                _case(
                    expected_answer="X is Y.",
                    grounding_doc_ids=["doc-a"],
                    notes="a note",
                )
            ],
        }
    )
    assert dataset.name == "mini"
    case = dataset.cases[0]
    assert case.relevant_doc_ids == ("doc-a",)
    assert case.expected_answer == "X is Y."
    assert case.grounding_doc_ids == ("doc-a",)
    assert case.notes == "a note"


def test_top_level_list_form_is_accepted():
    dataset = parse_dataset([_case()])
    assert len(dataset.cases) == 1


def test_unknown_query_type_is_rejected():
    with pytest.raises(DatasetValidationError, match="unknown query_type"):
        parse_dataset([_case(query_type="semantic")])


@pytest.mark.parametrize("missing", ["id", "query_type", "query", "relevant_doc_ids"])
def test_missing_required_field_is_rejected(missing):
    case = _case()
    del case[missing]
    with pytest.raises(DatasetValidationError, match="missing required field"):
        parse_dataset([case])


def test_empty_relevant_doc_ids_is_rejected():
    with pytest.raises(DatasetValidationError, match="relevant_doc_ids"):
        parse_dataset([_case(relevant_doc_ids=[])])


def test_duplicate_case_id_is_rejected():
    with pytest.raises(DatasetValidationError, match="duplicate case id"):
        parse_dataset([_case(), _case()])


def test_unknown_field_is_rejected():
    with pytest.raises(DatasetValidationError, match="unknown field"):
        parse_dataset([_case(surprise="nope")])


def test_load_dataset_rejects_invalid_json(tmp_path):
    path = tmp_path / "bad.json"
    path.write_text("{not json", encoding="utf-8")
    with pytest.raises(DatasetValidationError, match="not valid JSON"):
        load_dataset(path)


# --- Scoring math ---------------------------------------------------------


def test_recall_at_k_known_rankings():
    ranked = ("doc-x", "doc-a", "doc-y", "doc-b", "doc-z")
    relevant = ("doc-a", "doc-b", "doc-c")
    assert recall_at_k(ranked, relevant, k=1) == 0.0
    assert recall_at_k(ranked, relevant, k=2) == pytest.approx(1 / 3)
    assert recall_at_k(ranked, relevant, k=5) == pytest.approx(2 / 3)


def test_recall_at_k_perfect_and_empty():
    assert recall_at_k(("doc-a",), ("doc-a",), k=5) == 1.0
    assert recall_at_k((), ("doc-a",), k=5) == 0.0
    assert recall_at_k(("doc-a",), (), k=5) == 0.0


def test_hit_at_k_known_rankings():
    ranked = ("doc-x", "doc-a")
    assert hit_at_k(ranked, ("doc-a",), k=1) is False
    assert hit_at_k(ranked, ("doc-a",), k=2) is True
    assert hit_at_k(ranked, ("doc-nope",), k=2) is False


def test_recall_at_k_rejects_zero_k():
    with pytest.raises(ValueError, match="k must be"):
        recall_at_k(("doc-a",), ("doc-a",), k=0)


# --- Ablation plumbing ----------------------------------------------------

# Fixed rankings per config, keyed by query text. Deliberately different per
# config so grouping/aggregation differences are observable.
_RANKINGS = {
    "vector_only": {
        "q-lookup": RetrievalResult(("doc-a", "doc-x")),
        "q-hop": RetrievalResult(("doc-x", "doc-y")),
        "q-global": RetrievalResult(("doc-g",)),
    },
    "hybrid_no_graph": {
        "q-lookup": RetrievalResult(("doc-a",), grounding_score=0.5),
        "q-hop": RetrievalResult(("doc-h1", "doc-x"), grounding_score=0.7),
        "q-global": RetrievalResult(("doc-g", "doc-x"), grounding_score=0.9),
    },
    "hybrid_with_graph": {
        "q-lookup": RetrievalResult(("doc-a",), grounding_score=1.0),
        "q-hop": RetrievalResult(("doc-h1", "doc-h2"), grounding_score=1.0),
        "q-global": RetrievalResult(("doc-g", "doc-g2"), grounding_score=1.0),
    },
}


class FakeRetriever:
    def retrieve(self, config, query):
        return _RANKINGS[config][query]


def _ablation_dataset():
    return parse_dataset(
        [
            _case(
                id="l1",
                query_type="lookup",
                query="q-lookup",
                relevant_doc_ids=["doc-a"],
            ),
            _case(
                id="m1",
                query_type="multi_hop",
                query="q-hop",
                relevant_doc_ids=["doc-h1", "doc-h2"],
            ),
            _case(
                id="g1",
                query_type="global",
                query="q-global",
                relevant_doc_ids=["doc-g", "doc-g2"],
            ),
        ],
        name="ablation-fixture",
    )


def test_ablation_groups_metrics_per_query_type():
    results = run_ablation(_ablation_dataset(), FakeRetriever(), k=5)
    vector = results.config("vector_only")
    assert vector.by_query_type["lookup"].recall_at_k == 1.0
    assert vector.by_query_type["multi_hop"].recall_at_k == 0.0
    assert vector.by_query_type["multi_hop"].hit_rate == 0.0
    assert vector.by_query_type["global"].recall_at_k == 0.5
    assert vector.overall.case_count == 3
    assert vector.overall.recall_at_k == pytest.approx((1.0 + 0.0 + 0.5) / 3)
    assert vector.overall.hit_rate == pytest.approx(2 / 3)


def test_ablation_configs_produce_different_results():
    results = run_ablation(_ablation_dataset(), FakeRetriever(), k=5)
    recalls = {c.config: c.overall.recall_at_k for c in results.configs}
    assert recalls["vector_only"] == pytest.approx(0.5)
    assert recalls["hybrid_no_graph"] == pytest.approx((1.0 + 0.5 + 0.5) / 3)
    assert recalls["hybrid_with_graph"] == 1.0
    assert len({round(v, 6) for v in recalls.values()}) == 3


def test_ablation_grounding_pass_through_and_absence():
    results = run_ablation(_ablation_dataset(), FakeRetriever(), k=5)
    # vector_only provides no grounding scores: reported as absent, not 0.
    assert results.config("vector_only").overall.grounding_score is None
    hybrid = results.config("hybrid_no_graph")
    assert hybrid.overall.grounding_score == pytest.approx((0.5 + 0.7 + 0.9) / 3)
    assert hybrid.by_query_type["multi_hop"].grounding_score == pytest.approx(0.7)
    assert results.config("hybrid_with_graph").overall.grounding_score == 1.0


def test_ablation_k_is_parameterizable():
    results = run_ablation(_ablation_dataset(), FakeRetriever(), k=1)
    vector = results.config("vector_only")
    assert vector.by_query_type["global"].recall_at_k == 0.5
    graph = results.config("hybrid_with_graph")
    assert graph.by_query_type["multi_hop"].recall_at_k == 0.5


def test_ablation_rejects_unknown_config():
    with pytest.raises(ValueError, match="unknown configuration"):
        run_ablation(
            _ablation_dataset(), FakeRetriever(), configs=("vector_only", "magic")
        )


def test_ablation_all_default_configs_present():
    results = run_ablation(_ablation_dataset(), FakeRetriever())
    assert tuple(c.config for c in results.configs) == CONFIGURATIONS


# --- Report generation ----------------------------------------------------


def test_results_dict_structure():
    data = results_to_dict(run_ablation(_ablation_dataset(), FakeRetriever(), k=5))
    assert data["dataset"] == "ablation-fixture"
    assert data["k"] == 5
    assert set(data["configurations"]) == set(CONFIGURATIONS)
    vector = data["configurations"]["vector_only"]
    assert set(vector) == {"overall", "by_query_type", "cases"}
    assert set(vector["overall"]) == {
        "case_count",
        "recall_at_k",
        "hit_rate",
        "grounding_score",
    }
    assert set(vector["by_query_type"]) == {"lookup", "multi_hop", "global"}
    assert vector["overall"]["grounding_score"] is None
    assert len(vector["cases"]) == 3
    # Must be JSON-serializable as-is.
    json.dumps(data)


def test_markdown_report_has_per_type_sections_and_config_names():
    markdown = render_markdown(run_ablation(_ablation_dataset(), FakeRetriever()))
    assert "## Overall" in markdown
    for query_type in QUERY_TYPES:
        assert f"## Query type: {query_type}" in markdown
    for config in CONFIGURATIONS:
        assert config in markdown
    assert "Recall@5" in markdown


def test_markdown_report_renders_na_for_missing_grounding():
    markdown = render_markdown(run_ablation(_ablation_dataset(), FakeRetriever()))
    assert "n/a" in markdown
