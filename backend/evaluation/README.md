# Veraxi Evaluation Harness

This directory contains Veraxi's offline Code-Intel benchmarks and the resumable 4-stage Hybrid GraphRAG evaluation suite.

## 1. Offline Code-Intel Benchmarks (CPU-Only, Sub-Second)

```bash
backend/.venv/bin/python -m backend.evaluation.code_e2e_benchmark
backend/.venv/bin/pytest backend/tests/test_code_accuracy_eval.py backend/tests/test_code_e2e_benchmark.py
```

## 2. Resumable 4-Stage Hybrid GraphRAG Benchmark (`benchmark_rag.py`)

`benchmark_rag.py` compares `vector_only` against `hybrid_with_graph` (Neo4j + Qdrant + RRF) across four decoupled, checkpointed stages:

1. **`retrieve`**: Runs Qdrant + Neo4j retrieval only (no LLM), computing `recall@k`, `mrr`, `hit_rate`, latency, and context tokens.
2. **`generate`**: Generates answers concurrently via `AsyncOpenAI` (`LLM_BASE_URL` / `LLM_MODEL_NAME`), checkpointing every case to `retrievals.jsonl` / `answers.jsonl`.
3. **`judge`**: Scores answers using zero-cost deterministic metrics (token F1 + `grounding.py`) and/or DeepEval metrics (`GEval`, `FaithfulnessMetric`, `AnswerRelevancyMetric`) via `OpenAIDeepEvalModel`. Supports separate `JUDGE_LLM_BASE_URL` / `JUDGE_LLM_API_KEY` / `JUDGE_LLM_MODEL_NAME` overrides to avoid self-preference bias.
4. **`aggregate`**: Emits per-`question_type` and overall summaries (`summary.json` + `report.md`).

### Quick Smoke Run (Local or Docker)

```bash
backend/.venv/bin/python -m backend.evaluation.benchmark_rag \
  --stage all --limit 20 --judge-mode deterministic \
  --checkpoint-dir backend/evaluation/checkpoints
```

Add `--fresh` to reset checkpoints, or omit it to resume from the last completed `case_id`.

## 3. Zero-API-Key Google Colab Pro Runner

See [notebooks/colab_rag_eval.ipynb](../../notebooks/colab_rag_eval.ipynb) to run the full 2,062-case GraphRAG-Bench suite on Colab Pro (A100 40GB / L4 24GB) using:
- Native Neo4j 5.26 + Qdrant binary (no Docker required) with Google Drive DB snapshots
- Local MoE models (`Qwen3-30B-A3B-Instruct-2507` + `openai/gpt-oss-20b` cross-family judge) served via vLLM with XGrammar structured JSON outputs
