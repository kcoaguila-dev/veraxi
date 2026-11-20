"""Evidence-eval ablation CLI (WP1).

Offline by default: uses backend.evaluation (load_dataset,
RecordedRankingsRetriever, run_ablation, render_markdown/results_to_dict).
--remote posts dataset+rankings to POST /api/v1/evals/ablation.
Exit codes: 0 ok, 1 error/bad JSON, 2 threshold gate failed.
"""

import json
import sys
from pathlib import Path


def _load_json_file(path, label):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"Error: {label} file not found: {path}", file=sys.stderr)
        sys.exit(1)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"Error: invalid {label} JSON in {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print(f"Error: {label} file must contain a JSON object: {path}", file=sys.stderr)
        sys.exit(1)
    return data


def _check_thresholds(results_dict, min_recall=None, min_hit_rate=None, min_grounding=None):
    """Return list of failure strings; empty = pass. Checks per-query_type and overall."""
    failures = []
    thresholds = (("recall_at_k", min_recall), ("hit_rate", min_hit_rate), ("grounding_score", min_grounding))
    if all(v is None for _, v in thresholds):
        return failures
    for config, payload in (results_dict.get("configurations") or {}).items():
        groups = {"overall": payload.get("overall") or {}}
        groups.update(payload.get("by_query_type") or {})
        for group_name, metrics in groups.items():
            if not isinstance(metrics, dict):
                continue
            for metric, threshold in thresholds:
                if threshold is None:
                    continue
                value = metrics.get(metric)
                if value is None:
                    continue
                if float(value) < float(threshold):
                    failures.append(
                        f"{config}/{group_name}: {metric}={value} below threshold {threshold}"
                    )
    return failures


def _print_human(results_dict):
    print(f"Dataset: {results_dict.get('dataset')}  k={results_dict.get('k')}")
    for config, payload in (results_dict.get("configurations") or {}).items():
        print(f"\n{config}:")
        groups = {"overall": payload.get("overall") or {}}
        groups.update(payload.get("by_query_type") or {})
        for group_name, m in groups.items():
            if not isinstance(m, dict):
                continue
            grounding = m.get("grounding_score")
            g = "n/a" if grounding is None else f"{grounding:.3f}"
            print(
                f"  {group_name}: cases={m.get('case_count')} "
                f"recall@{results_dict.get('k')}={m.get('recall_at_k')} "
                f"hit_rate={m.get('hit_rate')} grounding={g}"
            )


def _remote_ablation(dataset_data, rankings, k, endpoint, key, tenant=None):
    from veraxi.cli.http_client import api_request

    body = {"dataset": dataset_data, "rankings": rankings, "k": k}
    return api_request("POST", "/api/v1/evals/ablation", body=body, endpoint=endpoint, key=key, tenant=tenant)


def run_eval_ablation(
    dataset=None,
    rankings=None,
    k=5,
    as_json=False,
    out_markdown=None,
    remote=False,
    endpoint="https://api.veraxi.me/sse",
    key=None,
    tenant=None,
    min_recall=None,
    min_hit_rate=None,
    min_grounding=None,
    repo_root=None,
):
    if not dataset or (not rankings and not repo_root):
        print(
            "Error: --dataset and (--rankings or --repo-root) are required.",
            file=sys.stderr,
        )
        sys.exit(1)
    if remote and not rankings:
        print("Error: --remote requires --rankings.", file=sys.stderr)
        sys.exit(1)
    dataset_data = _load_json_file(dataset, "dataset")

    markdown_text = None
    if remote:
        rankings_data = _load_json_file(rankings, "rankings")
        results_dict = _remote_ablation(dataset_data, rankings_data, k, endpoint, key, tenant)
    else:
        try:
            from backend.evaluation.ablation import run_ablation
            from backend.evaluation.report import render_markdown, results_to_dict
            from backend.evaluation.run_typed_ablation import RecordedRankingsRetriever
            from backend.evaluation.typed_dataset import load_dataset
        except ImportError as exc:
            print(f"Error: offline eval requires local backend.evaluation: {exc}", file=sys.stderr)
            sys.exit(1)
        try:
            typed = load_dataset(dataset)
            if repo_root:
                from backend.evaluation.code_ablation import RepoCodeAblationRetriever

                retriever = RepoCodeAblationRetriever(repo_root)
            else:
                rankings_data = _load_json_file(rankings, "rankings")
                retriever = RecordedRankingsRetriever(rankings_data)
            results = run_ablation(typed, retriever, k=k)
        except Exception as exc:
            print(f"Error: ablation failed: {exc}", file=sys.stderr)
            sys.exit(1)
        results_dict = results_to_dict(results)
        markdown_text = render_markdown(results)

    if out_markdown:
        text = markdown_text
        if text is None:
            # Remote mode: render a minimal markdown from dict via local renderer if available,
            # otherwise JSON-in-markdown fallback is avoided — synthesize tables from dict.
            lines = [f"# Evidence Eval Ablation Report\n\nDataset: `{results_dict.get('dataset')}` — k={results_dict.get('k')}.\n"]
            for config, payload in (results_dict.get("configurations") or {}).items():
                o = payload.get("overall") or {}
                lines.append(f"- {config}: recall={o.get('recall_at_k')} hit_rate={o.get('hit_rate')} grounding={o.get('grounding_score')}")
            text = "\n".join(lines) + "\n"
        try:
            Path(out_markdown).write_text(text, encoding="utf-8")
        except OSError as exc:
            print(f"Error: could not write {out_markdown}: {exc}", file=sys.stderr)
            sys.exit(1)

    if as_json:
        print(json.dumps(results_dict, indent=2))
    elif markdown_text and not out_markdown:
        print(markdown_text, end="")
    elif not out_markdown:
        _print_human(results_dict)
    else:
        _print_human(results_dict)

    failures = _check_thresholds(results_dict, min_recall, min_hit_rate, min_grounding)
    if failures:
        for failure in failures:
            print(f"Gate failed: {failure}", file=sys.stderr)
        sys.exit(2)
    sys.exit(0)
