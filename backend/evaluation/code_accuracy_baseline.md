# Code-accuracy baseline (Phase 16, ADR-0007)

Fixture: `backend/evaluation/code_accuracy.py` — 16 tricky Python
cases, 18 expected `CALLS` edges, measured through the real
`parse_repo` extraction. Re-run with `evaluate_cases()` from that
module (see `backend/tests/test_code_accuracy_eval.py`).

## Phase 0 baseline (2026-11-25, before the Phase 1 alias fix)

- Precision: **0.7333** (TP 11, FP 4)
- Recall: **0.6111** (FN 7)

Failing cases at baseline:

| Case | Result | Cause |
| --- | --- | --- |
| assignment-alias-same-file | FN 1 | resolver ignores assignment aliases |
| assignment-alias-of-import | FN 1 | resolver ignores assignment aliases |
| assignment-alias-called-directly | FN 1 | resolver ignores assignment aliases |
| init-reexport-plain | FP 1 + FN 1 | edge targets `pkg.build_video_item`, definition is `pkg.impl.build_video_item` |
| init-reexport-renamed-dogfood | FP 1 + FN 1 | edge targets `pkg._build_video_item`, definition is `pkg.impl.build_video_item` |
| init-assignment-reexport | FP 1 + FN 1 | same re-export mismatch, via an assignment in `__init__` |
| chained-reexport-two-packages | FP 1 + FN 1 | re-export chain never followed |

Already working at baseline (verified, not assumed):
`from x import y as _y` used directly in the importing file,
function-local imports (plain and `as`), module imports
(`import m as alias` + attribute call), same-file calls, self-method
calls, and same-name functions in different modules staying separate.

## Phase 1 result (2026-11-25, after the alias fix)

- Precision: **1.0000** (TP 18, FP 0)
- Recall: **1.0000** (FN 0)

All 16 cases pass. The earlier "0.89–0.92" estimate language is
retired in favour of these measured fixture numbers (ADR-0007).

## Phase 3 SCIP comparison (2026-11-25, spike — ADR-0007)

Same fixture, SCIP (scip-python 0.6.8 → `scip print --json` →
`parse_scip_payload`, after a mechanical camelCase→snake_case key
translation the shipped parser does not yet do):

- SCIP: **14 / 18** expected edges. Misses: all three
  assignment-alias cases and the assignment re-export case
  (pyright points the reference at the alias variable, not through
  it to the definition).
- AST (post-Phase-1): **18 / 18**.

On six constructed harder patterns (inherited-method dispatch,
`import pkg.sub` chain, instance-method calls ×2, cross-file
classmethod, dict-dispatch control): AST 0/6, SCIP 5/6 — the five
SCIP-only correct edges are the Phase 3 criterion-(b) evidence.
The fixture therefore no longer discriminates in SCIP's favour;
the two resolvers are complementary. Full spike record: ADR-0007.
