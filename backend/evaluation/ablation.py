"""Offline ablation runner for evidence-first retrieval configurations.

Compares retrieval configurations (``vector_only``, ``hybrid_no_graph`` and
``hybrid_with_graph``) over a typed dataset, behind an injectable retriever
interface so the core runner never touches a database, the network or an
LLM. Real retrievers (Qdrant / hybrid / GraphRAG) and test doubles both
implement the same :class:`Retriever` protocol.

Metrics: per-query-type and overall recall@k and hit-rate, plus the mean
grounding score when the retriever provides one (``None`` otherwise — a
missing grounding score is reported as absent, never invented as 0).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from backend.evaluation.typed_dataset import QUERY_TYPES, EvalCase, TypedDataset

CONFIGURATIONS: tuple[str, ...] = (
    "vector_only",
    "hybrid_no_graph",
    "hybrid_with_graph",
)
CODE_ABLATION_CONFIGURATIONS: tuple[str, ...] = (
    "vector_only",
    "hybrid_no_graph",
    "hybrid_with_graph",
    "hybrid_with_graph_rerank",
)
ALL_CONFIGURATIONS: tuple[str, ...] = CODE_ABLATION_CONFIGURATIONS

DEFAULT_K = 5


@dataclass(frozen=True)
class RetrievalResult:
    """One retriever response: ranked doc ids plus optional grounding."""

    ranked_doc_ids: tuple[str, ...]
    grounding_score: float | None = None


@runtime_checkable
class Retriever(Protocol):
    """Injectable retriever interface for the ablation runner."""

    def retrieve(self, config: str, query: str) -> RetrievalResult:
        """Return ranked doc ids for ``query`` under configuration ``config``."""
        ...


def recall_at_k(
    ranked_doc_ids: tuple[str, ...], relevant_doc_ids: tuple[str, ...], k: int
) -> float:
    """Fraction of relevant docs present in the top-``k`` ranked docs."""
    if k < 1:
        raise ValueError("k must be >= 1")
    if not relevant_doc_ids:
        return 0.0
    top_k = set(ranked_doc_ids[:k])
    hits = sum(1 for doc_id in relevant_doc_ids if doc_id in top_k)
    return hits / len(relevant_doc_ids)


def hit_at_k(
    ranked_doc_ids: tuple[str, ...], relevant_doc_ids: tuple[str, ...], k: int
) -> bool:
    """True when at least one relevant doc appears in the top-``k``."""
    if k < 1:
        raise ValueError("k must be >= 1")
    top_k = set(ranked_doc_ids[:k])
    return any(doc_id in top_k for doc_id in relevant_doc_ids)


@dataclass(frozen=True)
class CaseScore:
    """Scored result for a single case under a single configuration."""

    case_id: str
    query_type: str
    config: str
    recall_at_k: float
    hit: bool
    grounding_score: float | None


@dataclass(frozen=True)
class GroupMetrics:
    """Aggregated metrics for one group of cases (a query type or overall)."""

    case_count: int
    recall_at_k: float
    hit_rate: float
    grounding_score: float | None


@dataclass(frozen=True)
class ConfigResults:
    """All metrics for one configuration."""

    config: str
    k: int
    overall: GroupMetrics
    by_query_type: dict[str, GroupMetrics]
    case_scores: tuple[CaseScore, ...]


@dataclass(frozen=True)
class AblationResults:
    """Full ablation outcome across every requested configuration."""

    dataset_name: str
    k: int
    configs: tuple[ConfigResults, ...]

    def config(self, name: str) -> ConfigResults:
        for config_results in self.configs:
            if config_results.config == name:
                return config_results
        raise KeyError(f"no results for configuration '{name}'")


def _aggregate(scores: list[CaseScore]) -> GroupMetrics:
    if not scores:
        return GroupMetrics(
            case_count=0, recall_at_k=0.0, hit_rate=0.0, grounding_score=None
        )
    grounding_values = [
        s.grounding_score for s in scores if s.grounding_score is not None
    ]
    return GroupMetrics(
        case_count=len(scores),
        recall_at_k=sum(s.recall_at_k for s in scores) / len(scores),
        hit_rate=sum(1 for s in scores if s.hit) / len(scores),
        grounding_score=(
            sum(grounding_values) / len(grounding_values) if grounding_values else None
        ),
    )


def _score_case(retriever: Retriever, config: str, case: EvalCase, k: int) -> CaseScore:
    result = retriever.retrieve(config, case.query)
    if not isinstance(result, RetrievalResult):
        raise TypeError(
            f"retriever returned {type(result).__name__} for case '{case.id}' "
            f"under config '{config}'; expected RetrievalResult"
        )
    return CaseScore(
        case_id=case.id,
        query_type=case.query_type,
        config=config,
        recall_at_k=recall_at_k(result.ranked_doc_ids, case.relevant_doc_ids, k),
        hit=hit_at_k(result.ranked_doc_ids, case.relevant_doc_ids, k),
        grounding_score=result.grounding_score,
    )


def _run_config(
    retriever: Retriever, config: str, dataset: TypedDataset, k: int
) -> ConfigResults:
    case_scores = tuple(
        _score_case(retriever, config, case, k) for case in dataset.cases
    )
    by_query_type = {
        query_type: _aggregate([s for s in case_scores if s.query_type == query_type])
        for query_type in QUERY_TYPES
        if any(s.query_type == query_type for s in case_scores)
    }
    return ConfigResults(
        config=config,
        k=k,
        overall=_aggregate(list(case_scores)),
        by_query_type=by_query_type,
        case_scores=case_scores,
    )


def run_ablation(
    dataset: TypedDataset,
    retriever: Retriever,
    *,
    configs: tuple[str, ...] = CONFIGURATIONS,
    k: int = DEFAULT_K,
) -> AblationResults:
    """Run every requested configuration over ``dataset`` and aggregate.

    Fully offline: all retrieval goes through the injected ``retriever``.
    """
    if k < 1:
        raise ValueError("k must be >= 1")
    if not configs:
        raise ValueError("at least one configuration is required")
    unknown = [config for config in configs if config not in ALL_CONFIGURATIONS]
    if unknown:
        raise ValueError(
            f"unknown configuration(s): {', '.join(unknown)} "
            f"(expected one of: {', '.join(ALL_CONFIGURATIONS)})"
        )
    return AblationResults(
        dataset_name=dataset.name,
        k=k,
        configs=tuple(_run_config(retriever, config, dataset, k) for config in configs),
    )


__all__ = [
    "ALL_CONFIGURATIONS",
    "CODE_ABLATION_CONFIGURATIONS",
    "CONFIGURATIONS",
    "DEFAULT_K",
    "AblationResults",
    "CaseScore",
    "ConfigResults",
    "GroupMetrics",
    "RetrievalResult",
    "Retriever",
    "hit_at_k",
    "recall_at_k",
    "run_ablation",
]
