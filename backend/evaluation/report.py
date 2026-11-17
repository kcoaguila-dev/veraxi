"""Report generation for evidence-eval ablation results.

Turns :class:`~backend.evaluation.ablation.AblationResults` into a
JSON-serializable results dict and a human-readable markdown summary
grouped by query type, with a configuration comparison table.
"""

from __future__ import annotations

from typing import Any

from backend.evaluation.ablation import AblationResults, GroupMetrics
from backend.evaluation.typed_dataset import QUERY_TYPES


def _group_to_dict(metrics: GroupMetrics) -> dict[str, Any]:
    return {
        "case_count": metrics.case_count,
        "recall_at_k": round(metrics.recall_at_k, 4),
        "hit_rate": round(metrics.hit_rate, 4),
        "grounding_score": (
            round(metrics.grounding_score, 4)
            if metrics.grounding_score is not None
            else None
        ),
    }


def results_to_dict(results: AblationResults) -> dict[str, Any]:
    """Serialize ablation results to a JSON-ready dict."""
    return {
        "dataset": results.dataset_name,
        "k": results.k,
        "configurations": {
            config_results.config: {
                "overall": _group_to_dict(config_results.overall),
                "by_query_type": {
                    query_type: _group_to_dict(metrics)
                    for query_type, metrics in config_results.by_query_type.items()
                },
                "cases": [
                    {
                        "case_id": score.case_id,
                        "query_type": score.query_type,
                        "recall_at_k": round(score.recall_at_k, 4),
                        "hit": score.hit,
                        "grounding_score": (
                            round(score.grounding_score, 4)
                            if score.grounding_score is not None
                            else None
                        ),
                    }
                    for score in config_results.case_scores
                ],
            }
            for config_results in results.configs
        },
    }


def _fmt(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.3f}"


def _comparison_table(results: AblationResults, query_type: str | None) -> list[str]:
    label = "overall" if query_type is None else query_type
    lines = [
        f"| Config | Cases | Recall@{results.k} | Hit rate | Grounding |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for config_results in results.configs:
        metrics = (
            config_results.overall
            if query_type is None
            else config_results.by_query_type.get(query_type)
        )
        if metrics is None:
            continue
        lines.append(
            f"| {config_results.config} | {metrics.case_count} | "
            f"{metrics.recall_at_k:.3f} | {metrics.hit_rate:.3f} | "
            f"{_fmt(metrics.grounding_score)} |"
        )
    if len(lines) == 2:
        lines.append(f"| _(no cases for {label})_ | 0 | n/a | n/a | n/a |")
    return lines


def render_markdown(results: AblationResults) -> str:
    """Render a markdown summary grouped by query type."""
    lines = [
        "# Evidence Eval Ablation Report",
        "",
        f"Dataset: `{results.dataset_name}` — recall@k / hit-rate with k={results.k}.",
        "",
        "## Overall",
        "",
        *_comparison_table(results, None),
        "",
    ]
    present_types = [
        query_type
        for query_type in QUERY_TYPES
        if any(query_type in c.by_query_type for c in results.configs)
    ]
    for query_type in present_types:
        lines += [
            f"## Query type: {query_type}",
            "",
            *_comparison_table(results, query_type),
            "",
        ]
    return "\n".join(lines).rstrip() + "\n"


__all__ = ["render_markdown", "results_to_dict"]
