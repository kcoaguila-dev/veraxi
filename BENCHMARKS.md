# Benchmarks

Every number Veraxi publishes lives here, with its fixture, its method,
and its caveats. If a number is not on this page, it is not a claim we
make. If a result is weak or incomplete, it is recorded as such —
a benchmark you cannot reproduce is marketing, and this project exists
because its author did not want to take an AI's word for anything.

## 1. Code-graph accuracy fixture (CALLS edges)

**What it measures:** whether the code graph's `CALLS` edges are right —
the property `impact_analysis` and the Security workbench's
reachability verdicts stand on. A wrong "not reachable" is the
dangerous direction, so precision *and* recall are both reported.

**Fixture:** `backend/evaluation/code_accuracy.py` — 16 tricky Python
cases, 18 expected `CALLS` edges, measured through the real
`parse_repo` extraction (not a mock). Record:
`backend/evaluation/code_accuracy_baseline.md`; design record:
`docs/adr/0007-compiler-grade-code-intelligence.md`.

| Resolver | Precision | Recall | Notes |
| --- | --- | --- | --- |
| AST, Phase 0 baseline (2026-11-25) | 0.7333 (TP 11, FP 4) | 0.6111 (FN 7) | Misses: assignment aliases ×3; `__init__` re-exports produced FP+FN pairs |
| AST, after Phase 1 alias fix (2026-11-25) | 1.0000 (TP 18, FP 0) | 1.0000 (FN 0) | All 16 cases pass |
| SCIP (scip-python 0.6.8), same fixture | — | 14 / 18 edges | Misses all three assignment-alias cases and the assignment re-export |

On six constructed harder patterns (inherited-method dispatch,
`import pkg.sub` chains, instance-method calls, cross-file classmethod,
dict-dispatch): **AST 0/6, SCIP 5/6**. The two resolvers are
complementary, which is why both are kept and why edges carry
provenance (`graph_source`) instead of a bare true/false.

**Why this fixture exists:** in dogfooding against veraxi-ymmp,
CodeRabbit was 96.6% precise on a change where Veraxi's graph recalled
**0 of 28** callers of `build_video_item` / `_build_video_item`
(module-level assignment alias + `__init__` re-export). That miss is
the fixture's origin; it is recorded in ADR-0007, not hidden.

**Reproduce:**
```bash
cd backend && .venv/bin/pytest tests/test_code_accuracy_eval.py
```

## 2. SCIP indexer measurements (spike, 2026-11-25)

Measured while evaluating scip-python as an ingestion source
(ADR-0007). Indexer always invoked with `--project-version`.

| Target | Build | Time | Peak RSS | Index size |
| --- | --- | --- | --- | --- |
| Veraxi backend (311 files) | OK | 51.9 s | ~1.09 GB | 9.0 MB |
| itsdangerous (external) | OK | 4.9 s | ~290 MB | 394 KB |
| markupsafe (external, C extension) | OK | 8.5 s | ~290 MB | 144 KB |
| Constructed hard-cases project | OK | 3.7 s | — | — |
| Fixture cases (16 micro-projects) | 16/16 OK | 2–5 s each | — | — |

Caveat: single-machine spike numbers from the ADR, kept for the
decision record — not a performance claim about current ingestion.

## 3. Retrieval / RAG evaluation — infrastructure yes, headline number not yet

**Infrastructure (in `backend/evaluation/`):**

- A 150-question deterministic pipeline (`run_deterministic_suite.sh`)
  scored by token-overlap F1 (ROUGE-1 style), so it needs no
  LLM-as-a-judge API calls.
- A 2,062-question full pipeline (`run_full_suite.sh`) and a DeepEval
  benchmark (`benchmark_rag.py`) comparing vector-only RAG against
  Hybrid GraphRAG on a medical test corpus.
- Retrieval ablation tooling (`ablation.py`, `code_ablation.py`)
  reporting per-query-type recall@k and hit-rate.

**Current recorded state — read this before quoting anything:**
`backend/evaluation/results.json` records average correctness of
0.4473 (vector) vs 0.5629 (hybrid), **but that run scored only 1 of
150 test cases**; the rest were rate-limited. Those averages are
therefore *not* reliable and are **not** a published result. A clean
full run is required before any retrieval-quality number appears
here, and when it does it will be reported per query type
(recall@k / hit-rate), with the run's date, corpus, and config —
not as a single blended average.

**Reproduce:**
```bash
bash backend/evaluation/run_deterministic_suite.sh
PYTHONPATH=. python -m backend.evaluation.benchmark_rag   # full DeepEval suite
```

## What we do not claim

- No retrieval-quality percentage until a complete, un-rate-limited
  run is recorded as described above.
- No latency claims beyond the measured tables on this page.
- Fixture results (§1) are exactly that — a 16-case fixture. They
  prove the resolver handles those patterns; they do not prove
  accuracy on arbitrary codebases, and the hard-pattern row shows
  where the AST resolver still scores 0.
