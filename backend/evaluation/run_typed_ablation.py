"""Thin CLI for the typed evidence-eval ablation runner.

Fully offline: retrieval results come from a recorded rankings file, so no
database, network or LLM is involved. The rankings file maps each
configuration name to a mapping of query text -> ranked doc ids, with an
optional per-query grounding score:

    {
      "vector_only": {
        "What is ...?": {"ranked_doc_ids": ["doc-1"], "grounding_score": 0.8}
      }
    }

A bare list of doc ids per query is also accepted (no grounding score).

Usage:
    python -m backend.evaluation.run_typed_ablation \
        --dataset backend/evaluation/seed_dataset.json \
        --rankings rankings.json --k 5 \
        --out-json results.json --out-markdown report.md
"""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path
from typing import Any

from backend.evaluation.ablation import RetrievalResult, run_ablation
from backend.evaluation.report import render_markdown, results_to_dict
from backend.evaluation.typed_dataset import load_dataset

logger = logging.getLogger(__name__)


class RecordedRankingsRetriever:
    """Retriever backed by recorded rankings (config -> query -> ranking)."""

    def __init__(self, rankings: dict[str, dict[str, Any]]) -> None:
        self._rankings = rankings

    def retrieve(self, config: str, query: str) -> RetrievalResult:
        entry = self._rankings.get(config, {}).get(query)
        if entry is None:
            return RetrievalResult(ranked_doc_ids=())
        if isinstance(entry, list):
            return RetrievalResult(ranked_doc_ids=tuple(entry))
        return RetrievalResult(
            ranked_doc_ids=tuple(entry.get("ranked_doc_ids", [])),
            grounding_score=entry.get("grounding_score"),
        )


def _load_rankings(path: Path) -> dict[str, dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError("rankings file must be a JSON object keyed by config name")
    return data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, help="Typed dataset JSON path")
    source_group = parser.add_mutually_exclusive_group(required=True)
    source_group.add_argument("--rankings", help="Recorded rankings JSON path")
    source_group.add_argument(
        "--repo-root",
        help="Run live offline code-graph ablation over a local repository root",
    )
    parser.add_argument(
        "--k", type=int, default=5, help="Cutoff for recall@k / hit-rate"
    )
    parser.add_argument("--out-json", help="Write the results dict as JSON here")
    parser.add_argument("--out-markdown", help="Write the markdown report here")
    args = parser.parse_args()

    dataset = load_dataset(args.dataset)
    retriever: Any
    if args.repo_root:
        from backend.evaluation.code_ablation import RepoCodeAblationRetriever

        retriever = RepoCodeAblationRetriever(args.repo_root)
    else:
        retriever = RecordedRankingsRetriever(_load_rankings(Path(args.rankings)))
    results = run_ablation(dataset, retriever, k=args.k)

    if args.out_json:
        Path(args.out_json).write_text(
            json.dumps(results_to_dict(results), indent=2), encoding="utf-8"
        )
        logger.info("wrote JSON results to %s", args.out_json)
    if args.out_markdown:
        Path(args.out_markdown).write_text(render_markdown(results), encoding="utf-8")
        logger.info("wrote markdown report to %s", args.out_markdown)
    if not args.out_json and not args.out_markdown:
        logger.info("%s", render_markdown(results))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    main()
