"""Veraxi Resumable 4-Stage Hybrid GraphRAG Benchmark Suite.

Compares ``vector_only`` (Qdrant hybrid dense+sparse) against
``hybrid_with_graph`` (Neo4j + Qdrant + RRF) across four decoupled,
checkpointed stages:

1. ``retrieve``: Run retrieval only (no LLM), compute pure-arithmetic
   ``recall@k``, ``mrr``, ``hit_rate``, latency, and context tokens.
2. ``generate``: Generate RAG answers with ``AsyncOpenAI`` concurrency and
   append-only JSONL checkpoints.
3. ``judge``: Score answers using deterministic metrics (ROUGE-1 F1 +
   ``grounding.py``) and/or DeepEval metrics via ``OpenAIDeepEvalModel``.
4. ``aggregate``: Compute per-``question_type`` and overall summaries and
   render a ``BENCHMARKS.md``-compatible Markdown report.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import shutil
import statistics
import string
import time
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Awaitable, Callable

import sentry_sdk
from dotenv import load_dotenv
from openai import AsyncOpenAI

from backend.config import get_config
from backend.evaluation.deepeval_model import (
    OpenAIDeepEvalModel,
    strip_think_and_fences,
)
from backend.evaluation.grounding import evaluate_deterministic_grounding
from backend.retrieval.merge_rank import GraphHit, VectorHit, merge_rank

load_dotenv("backend/.env")

logger = logging.getLogger(__name__)

STRATEGIES: tuple[str, ...] = ("vector_only", "hybrid_with_graph")
MAX_RETRIES = 3
RETRY_BASE_DELAY_S = 10.0

_QUERY_STOPWORDS = frozenset(
    {
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "could",
        "did", "do", "does", "for", "from", "had", "has", "have", "how",
        "in", "is", "it", "its", "may", "might", "of", "on", "or", "should",
        "such", "that", "the", "their", "them", "these", "this", "to",
        "was", "were", "what", "when", "where", "which", "who", "whom",
        "whose", "why", "will", "with", "would",
    }
)


def _normalize_text(text: str) -> str:
    lowered = (text or "").lower().translate(str.maketrans("", "", string.punctuation))
    return " ".join(lowered.split())


def _token_f1(actual: str, expected: str) -> float:
    actual_tokens = set(_normalize_text(actual).split())
    expected_tokens = set(_normalize_text(expected).split())
    if not actual_tokens or not expected_tokens:
        return 0.0
    overlap = len(actual_tokens & expected_tokens)
    if overlap == 0:
        return 0.0
    precision = overlap / len(actual_tokens)
    recall = overlap / len(expected_tokens)
    return 2 * precision * recall / (precision + recall)


def derive_graph_entity(item: dict[str, Any]) -> str:
    """Derive a graph lookup query string from a dataset item."""
    explicit = str(item.get("entity") or "").strip()
    if explicit:
        return explicit

    query = str(item.get("query") or "").strip()
    tokens = re.findall(r"[A-Za-z0-9_-]+", query)
    keywords = [t for t in tokens if t.lower() not in _QUERY_STOPWORDS and len(t) > 1]
    if keywords:
        return " ".join(keywords[:6])
    return query


def _evidence_matches_context(evidence: str, contexts: list[str]) -> bool:
    norm_ev = _normalize_text(evidence)
    if not norm_ev:
        return False
    ev_tokens = set(norm_ev.split())
    for ctx in contexts:
        norm_ctx = _normalize_text(ctx)
        if norm_ev in norm_ctx:
            return True
        if ev_tokens:
            ctx_tokens = set(norm_ctx.split())
            if len(ev_tokens & ctx_tokens) / len(ev_tokens) >= 0.7:
                return True
    return False


def compute_retrieval_metrics(
    contexts: list[str], evidence: list[str] | None
) -> dict[str, Any]:
    """Compute recall@k, MRR, and hit for a single case's retrieved contexts."""
    if not evidence:
        return {"recall": None, "mrr": None, "hit": None}

    matched = sum(1 for ev in evidence if _evidence_matches_context(ev, contexts))
    recall = matched / len(evidence)

    first_rank: int | None = None
    for idx, ctx in enumerate(contexts, start=1):
        if any(_evidence_matches_context(ev, [ctx]) for ev in evidence):
            first_rank = idx
            break

    mrr = (1.0 / first_rank) if first_rank is not None else 0.0
    return {"recall": round(recall, 4), "mrr": round(mrr, 4), "hit": first_rank is not None}


def load_jsonl_checkpoint(path: Path) -> dict[str, dict[str, Any]]:
    """Load an append-only JSONL checkpoint keyed by ``case_id``."""
    records: dict[str, dict[str, Any]] = {}
    if not path.exists():
        return records
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            row = json.loads(stripped)
            case_id = str(row["case_id"])
            records[case_id] = row
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning("Skipping corrupt checkpoint line in %s: %s", path, exc)
    return records


def append_jsonl_checkpoint(path: Path, row: dict[str, Any]) -> None:
    """Append a single JSONL record and flush immediately."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        handle.flush()


def _retrieve_case(
    case_id: str,
    item: dict[str, Any],
    tenant_id: str,
    top_k: int,
    search_vectors_fn: Callable[..., list[Any]],
    query_graph_fn: Callable[..., list[Any]],
) -> dict[str, Any]:
    query = str(item["query"])
    evidence = item.get("evidence") or []
    entity = derive_graph_entity(item)

    t0 = time.perf_counter()
    v_raw = search_vectors_fn(query_text=query, limit=top_k, tenant_id=tenant_id)
    v_latency_ms = (time.perf_counter() - t0) * 1000.0
    v_contexts = [hit.payload.get("text", "") for hit in v_raw]
    v_text = "\n".join(v_contexts)
    v_metrics = compute_retrieval_metrics(v_contexts, evidence)

    t1 = time.perf_counter()
    v_for_hybrid = search_vectors_fn(query_text=query, limit=top_k, tenant_id=tenant_id)
    v_hits = [VectorHit(id=h.id, score=h.score, payload=h.payload) for h in v_for_hybrid]
    g_raw = query_graph_fn(entity_name=entity, max_hops=2, tenant_id=tenant_id)
    g_hits = [GraphHit(id=h.id, payload=h.payload) for h in g_raw]
    hybrid_hits = merge_rank(vector_hits=v_hits, graph_hits=g_hits, limit=top_k)
    h_latency_ms = (time.perf_counter() - t1) * 1000.0
    h_contexts = [hit.payload.get("text", "") for hit in hybrid_hits]
    h_text = "\n".join(h_contexts)
    h_metrics = compute_retrieval_metrics(h_contexts, evidence)

    return {
        "case_id": case_id,
        "question_type": str(item.get("question_type") or "unknown"),
        "query": query,
        "expected_answer": str(item.get("expected_answer") or ""),
        "evidence": evidence,
        "graph_entity": entity,
        "strategies": {
            "vector_only": {
                "contexts": v_contexts,
                "context_text": v_text,
                "latency_ms": round(v_latency_ms, 2),
                "context_tokens": max(1, len(v_text) // 4) if v_text else 0,
                **v_metrics,
            },
            "hybrid_with_graph": {
                "contexts": h_contexts,
                "context_text": h_text,
                "latency_ms": round(h_latency_ms, 2),
                "context_tokens": max(1, len(h_text) // 4) if h_text else 0,
                **h_metrics,
            },
        },
    }


def run_retrieve_stage(
    dataset: list[dict[str, Any]],
    checkpoint_path: Path,
    tenant_id: str = "benchmark",
    top_k: int = 5,
    resume: bool = True,
    search_vectors_fn: Callable[..., list[Any]] | None = None,
    query_graph_fn: Callable[..., list[Any]] | None = None,
) -> dict[str, dict[str, Any]]:
    """Stage 2: Execute retrieval across all strategies with JSONL checkpointing."""
    if search_vectors_fn is None:
        from backend.mcp_server.tools.search_vectors import search_vectors

        search_vectors_fn = search_vectors
    if query_graph_fn is None:
        from backend.mcp_server.tools.query_graph import query_graph

        query_graph_fn = query_graph

    completed = load_jsonl_checkpoint(checkpoint_path) if resume else {}
    for idx, item in enumerate(dataset):
        case_id = str(item.get("id") or f"case-{idx:04d}")
        if case_id in completed:
            continue
        row = _retrieve_case(
            case_id=case_id,
            item=item,
            tenant_id=tenant_id,
            top_k=top_k,
            search_vectors_fn=search_vectors_fn,
            query_graph_fn=query_graph_fn,
        )
        append_jsonl_checkpoint(checkpoint_path, row)
        completed[case_id] = row
        if (idx + 1) % 50 == 0:
            logger.info("Retrieve progress: %d/%d", idx + 1, len(dataset))
    return completed


def _build_default_async_generator() -> Callable[[str, str], Awaitable[str | None]]:
    config = get_config()
    llm_args = config.get_llm_client_args()
    if llm_args.get("base_url") and not llm_args.get("api_key"):
        llm_args["api_key"] = "local"
    client = AsyncOpenAI(**llm_args)
    model_name = config.llm_model_name

    async def _generate(query: str, context: str) -> str | None:
        prompt = (
            "Answer the following question using ONLY the provided context. "
            "If the context is insufficient, state that you cannot answer fully "
            "based on the context.\n\n"
            f"Context:\n{context}\n\n"
            f"Question:\n{query}"
        )
        for attempt in range(MAX_RETRIES):
            try:
                resp = await client.chat.completions.create(
                    model=model_name,
                    messages=[{"role": "user", "content": prompt}],
                    temperature=0.0,
                )
                return strip_think_and_fences(resp.choices[0].message.content or "")
            except Exception as exc:
                if "429" in str(exc) or "RESOURCE_EXHAUSTED" in str(exc):
                    await asyncio.sleep(RETRY_BASE_DELAY_S * (attempt + 1))
                    continue
                sentry_sdk.capture_exception(exc)
                logger.warning("Generation error for query: %s", exc)
                return None
        return None

    return _generate


async def run_generate_stage(
    retrievals: dict[str, dict[str, Any]],
    checkpoint_path: Path,
    resume: bool = True,
    concurrency: int = 16,
    delay_sec: float = 0.0,
    generate_fn: Callable[[str, str], Awaitable[str | None]] | None = None,
) -> dict[str, dict[str, Any]]:
    """Stage 3a: Generate answers concurrently and checkpoint to JSONL."""
    completed = load_jsonl_checkpoint(checkpoint_path) if resume else {}
    pending = [(cid, row) for cid, row in retrievals.items() if cid not in completed]
    if not pending:
        return completed

    gen_fn = generate_fn or _build_default_async_generator()
    semaphore = asyncio.Semaphore(max(1, concurrency))
    lock = asyncio.Lock()
    done_count = 0

    async def _worker(case_id: str, retrieval_row: dict[str, Any]) -> None:
        nonlocal done_count
        query = retrieval_row["query"]
        answers: dict[str, str | None] = {}
        async with semaphore:
            for strat in STRATEGIES:
                ctx_text = retrieval_row["strategies"][strat]["context_text"]
                raw_ans = await gen_fn(query, ctx_text)
                answers[strat] = (
                    strip_think_and_fences(raw_ans) if raw_ans is not None else None
                )
                if delay_sec > 0:
                    await asyncio.sleep(delay_sec)

        record = {
            "case_id": case_id,
            "question_type": retrieval_row["question_type"],
            "query": query,
            "expected_answer": retrieval_row["expected_answer"],
            "strategies": {
                strat: {
                    "answer": answers[strat],
                    "context_text": retrieval_row["strategies"][strat]["context_text"],
                    "contexts": retrieval_row["strategies"][strat]["contexts"],
                }
                for strat in STRATEGIES
            },
        }
        async with lock:
            append_jsonl_checkpoint(checkpoint_path, record)
            completed[case_id] = record
            done_count += 1
            if done_count % 50 == 0 or done_count == len(pending):
                logger.info("Generate progress: %d/%d new cases", done_count, len(pending))

    await asyncio.gather(*(_worker(cid, row) for cid, row in pending))
    return completed


def _build_deepeval_metrics(eval_llm: OpenAIDeepEvalModel) -> dict[str, Any]:
    from deepeval.metrics import (
        AnswerRelevancyMetric,
        FaithfulnessMetric,
        GEval,
    )
    from deepeval.test_case import LLMTestCaseParams

    return {
        "correctness": GEval(
            name="Correctness",
            criteria=(
                "Determine whether the actual output contains the expected output "
                "and is factually correct based on the expected output."
            ),
            evaluation_params=[
                LLMTestCaseParams.ACTUAL_OUTPUT,
                LLMTestCaseParams.EXPECTED_OUTPUT,
            ],
            model=eval_llm,
            threshold=0.5,
        ),
        "faithfulness": FaithfulnessMetric(threshold=0.5, model=eval_llm),
        "relevancy": AnswerRelevancyMetric(threshold=0.5, model=eval_llm),
    }


async def _score_deepeval_strategy(
    metrics_factory: Callable[[], dict[str, Any]],
    query: str,
    expected: str,
    answer: str,
    contexts: list[str],
) -> dict[str, float | None]:
    from deepeval.test_case import LLMTestCase

    test_case = LLMTestCase(
        input=query,
        actual_output=answer,
        expected_output=expected,
        retrieval_context=contexts or ["No context retrieved."],
    )
    metrics = metrics_factory()
    out: dict[str, float | None] = {}
    for key, metric in metrics.items():
        try:
            await metric.a_measure(test_case)
            out[key] = round(float(metric.score), 4) if metric.score is not None else None
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning("DeepEval metric %s failed: %s", key, exc)
            out[key] = None
    return out


async def run_judge_stage(
    answers: dict[str, dict[str, Any]],
    checkpoint_path: Path,
    resume: bool = True,
    concurrency: int = 16,
    judge_mode: str = "both",
    eval_llm: OpenAIDeepEvalModel | None = None,
) -> dict[str, dict[str, Any]]:
    """Stage 3b: Score generated answers with deterministic and/or DeepEval judges."""
    completed = load_jsonl_checkpoint(checkpoint_path) if resume else {}
    pending = [(cid, row) for cid, row in answers.items() if cid not in completed]
    if not pending:
        return completed

    use_deepeval = judge_mode in ("deepeval", "both")
    judge_model = eval_llm or (OpenAIDeepEvalModel() if use_deepeval else None)
    semaphore = asyncio.Semaphore(max(1, concurrency))
    lock = asyncio.Lock()
    done_count = 0

    async def _worker(case_id: str, ans_row: dict[str, Any]) -> None:
        nonlocal done_count
        strat_scores: dict[str, dict[str, Any]] = {}
        async with semaphore:
            for strat in STRATEGIES:
                s_data = ans_row["strategies"][strat]
                answer = s_data.get("answer")
                ctx_text = s_data.get("context_text", "")
                contexts = s_data.get("contexts", [])
                if not answer:
                    strat_scores[strat] = {
                        "f1": None,
                        "grounding": None,
                        "correctness": None,
                        "faithfulness": None,
                        "relevancy": None,
                    }
                    continue

                f1 = round(_token_f1(answer, ans_row["expected_answer"]), 4)
                grounding = evaluate_deterministic_grounding(answer, ctx_text)
                de_scores = {"correctness": None, "faithfulness": None, "relevancy": None}
                if use_deepeval and judge_model is not None:
                    de_scores = await _score_deepeval_strategy(
                        lambda: _build_deepeval_metrics(judge_model),
                        ans_row["query"],
                        ans_row["expected_answer"],
                        answer,
                        contexts,
                    )
                strat_scores[strat] = {
                    "f1": f1,
                    "grounding": round(float(grounding), 4) if grounding is not None else None,
                    **de_scores,
                }

        record = {
            "case_id": case_id,
            "question_type": ans_row["question_type"],
            "strategies": strat_scores,
        }
        async with lock:
            append_jsonl_checkpoint(checkpoint_path, record)
            completed[case_id] = record
            done_count += 1
            if done_count % 50 == 0 or done_count == len(pending):
                logger.info("Judge progress: %d/%d new cases", done_count, len(pending))

    await asyncio.gather(*(_worker(cid, row) for cid, row in pending))
    return completed


def _mean_or_none(values: list[float | int | None]) -> float | None:
    clean = [float(v) for v in values if v is not None]
    return round(statistics.mean(clean), 4) if clean else None


def _aggregate_group(
    case_ids: list[str],
    retrievals: dict[str, dict[str, Any]],
    scores: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    group: dict[str, dict[str, Any]] = {}
    for strat in STRATEGIES:
        r_rows = [retrievals[cid]["strategies"][strat] for cid in case_ids if cid in retrievals]
        s_rows = [scores[cid]["strategies"][strat] for cid in case_ids if cid in scores]
        hits = [1.0 if r.get("hit") else 0.0 for r in r_rows if r.get("hit") is not None]
        group[strat] = {
            "case_count": len(r_rows),
            "recall_at_k": _mean_or_none([r.get("recall") for r in r_rows]),
            "mrr": _mean_or_none([r.get("mrr") for r in r_rows]),
            "hit_rate": _mean_or_none(hits),
            "avg_latency_ms": _mean_or_none([r.get("latency_ms") for r in r_rows]),
            "avg_context_tokens": _mean_or_none([r.get("context_tokens") for r in r_rows]),
            "f1": _mean_or_none([s.get("f1") for s in s_rows]),
            "grounding": _mean_or_none([s.get("grounding") for s in s_rows]),
            "deepeval_correctness": _mean_or_none([s.get("correctness") for s in s_rows]),
            "deepeval_faithfulness": _mean_or_none([s.get("faithfulness") for s in s_rows]),
            "deepeval_relevancy": _mean_or_none([s.get("relevancy") for s in s_rows]),
        }
    return group


def aggregate_results(
    retrievals: dict[str, dict[str, Any]],
    scores: dict[str, dict[str, Any]],
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Stage 4: Aggregate per-question-type and overall metrics."""
    all_ids = sorted(retrievals.keys())
    by_type_ids: dict[str, list[str]] = defaultdict(list)
    for cid in all_ids:
        q_type = str(retrievals[cid].get("question_type") or "unknown")
        by_type_ids[q_type].append(cid)

    return {
        "generated_at": datetime.now(UTC).isoformat(),
        "total_cases": len(all_ids),
        "metadata": metadata or {},
        "overall": _aggregate_group(all_ids, retrievals, scores),
        "by_question_type": {
            q_type: _aggregate_group(cids, retrievals, scores)
            for q_type, cids in sorted(by_type_ids.items())
        },
    }


def _fmt(val: float | None) -> str:
    return "n/a" if val is None else f"{val:.4f}"


def _render_group_table(group: dict[str, dict[str, Any]]) -> list[str]:
    lines = [
        "| Strategy | Cases | Recall@K | MRR | Hit Rate | F1 | Grounding | Correctness | Faithfulness | Relevancy |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for strat in STRATEGIES:
        m = group.get(strat, {})
        lines.append(
            f"| `{strat}` | {m.get('case_count', 0)} | "
            f"{_fmt(m.get('recall_at_k'))} | {_fmt(m.get('mrr'))} | {_fmt(m.get('hit_rate'))} | "
            f"{_fmt(m.get('f1'))} | {_fmt(m.get('grounding'))} | "
            f"{_fmt(m.get('deepeval_correctness'))} | {_fmt(m.get('deepeval_faithfulness'))} | "
            f"{_fmt(m.get('deepeval_relevancy'))} |"
        )
    return lines


def render_benchmark_markdown(summary: dict[str, Any]) -> str:
    """Render a BENCHMARKS.md-ready Markdown report grouped by question_type."""
    meta = summary.get("metadata", {})
    lines = [
        "# Veraxi Hybrid GraphRAG Benchmark Report",
        "",
        f"- **Generated:** {summary.get('generated_at', '')}",
        f"- **Total cases:** {summary.get('total_cases', 0)}",
        f"- **Generator model:** `{meta.get('generator_model', 'unknown')}`",
        f"- **Judge model:** `{meta.get('judge_model', 'unknown')}`",
        "",
        "## Overall",
        "",
        *_render_group_table(summary.get("overall", {})),
        "",
    ]
    for q_type, group in summary.get("by_question_type", {}).items():
        lines.extend([f"## Question Type: `{q_type}`", "", *_render_group_table(group), ""])
    return "\n".join(lines)


def _load_dataset(dataset_path: Path, limit: int | None) -> list[dict[str, Any]]:
    data = json.loads(dataset_path.read_text(encoding="utf-8"))
    if limit is not None and limit > 0:
        return data[:limit]
    return data


def _build_cli_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--stage",
        choices=("all", "retrieve", "generate", "judge", "aggregate"),
        default="all",
    )
    parser.add_argument(
        "--dataset", default="backend/evaluation/dataset.json", help="Dataset JSON path"
    )
    parser.add_argument(
        "--checkpoint-dir",
        default="backend/evaluation/checkpoints",
        help="Directory for resumable JSONL checkpoints and final outputs",
    )
    parser.add_argument("--tenant-id", default="benchmark")
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--limit", type=int, default=0, help="0 means full dataset")
    parser.add_argument("--fresh", action="store_true", help="Clear existing checkpoints")
    parser.add_argument("--concurrency", type=int, default=0, help="0 = auto by LLM_BASE_URL")
    parser.add_argument("--delay-sec", type=float, default=-1.0, help="-1 = auto by LLM_BASE_URL")
    parser.add_argument(
        "--judge-mode",
        choices=("both", "deepeval", "deterministic"),
        default="both",
    )
    return parser


def main() -> None:
    args = _build_cli_parser().parse_args()
    ckpt_dir = Path(args.checkpoint_dir)
    if args.fresh and ckpt_dir.exists():
        shutil.rmtree(ckpt_dir)
    ckpt_dir.mkdir(parents=True, exist_ok=True)

    is_local = bool(os.environ.get("LLM_BASE_URL", "").strip())
    concurrency = args.concurrency if args.concurrency > 0 else (16 if is_local else 1)
    delay_sec = args.delay_sec if args.delay_sec >= 0 else (0.0 if is_local else 15.0)
    resume = not args.fresh

    retrievals_path = ckpt_dir / "retrievals.jsonl"
    answers_path = ckpt_dir / "answers.jsonl"
    scores_path = ckpt_dir / "scores.jsonl"

    dataset = _load_dataset(Path(args.dataset), args.limit or None)

    if args.stage in ("all", "retrieve"):
        retrievals = run_retrieve_stage(
            dataset=dataset,
            checkpoint_path=retrievals_path,
            tenant_id=args.tenant_id,
            top_k=args.top_k,
            resume=resume,
        )
    else:
        retrievals = load_jsonl_checkpoint(retrievals_path)

    if args.stage in ("all", "generate"):
        answers = asyncio.run(
            run_generate_stage(
                retrievals=retrievals,
                checkpoint_path=answers_path,
                resume=resume,
                concurrency=concurrency,
                delay_sec=delay_sec,
            )
        )
    else:
        answers = load_jsonl_checkpoint(answers_path)

    if args.stage in ("all", "judge"):
        scores = asyncio.run(
            run_judge_stage(
                answers=answers,
                checkpoint_path=scores_path,
                resume=resume,
                concurrency=concurrency,
                judge_mode=args.judge_mode,
            )
        )
    else:
        scores = load_jsonl_checkpoint(scores_path)

    if args.stage in ("all", "aggregate"):
        cfg = get_config()
        judge_name = (
            os.environ.get("JUDGE_LLM_MODEL_NAME", "").strip()
            or cfg.llm_model_name
            or "deterministic"
        )
        summary = aggregate_results(
            retrievals=retrievals,
            scores=scores,
            metadata={
                "dataset": args.dataset,
                "embedding_model": cfg.embedding_model_name,
                "generator_model": cfg.llm_model_name,
                "judge_model": judge_name if args.judge_mode != "deterministic" else "deterministic",
            },
        )
        (ckpt_dir / "summary.json").write_text(
            json.dumps(summary, indent=2), encoding="utf-8"
        )
        md = render_benchmark_markdown(summary)
        (ckpt_dir / "report.md").write_text(md, encoding="utf-8")
        logger.info("\n%s", md)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    main()
