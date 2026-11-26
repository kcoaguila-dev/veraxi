# 7. Compiler-Grade Code Intelligence (SCIP, Linters-as-Claims, Resolution Provenance)

Date: 2026-11-25

## Status

Proposed

## Context

Veraxi's code graph is built by conservative AST parsing (Python stdlib
`ast`) plus tree-sitter / regex fallbacks for other languages
(`backend/ingestion/code_graph.py`). That under-claiming discipline is
deliberate, but it has a measured cost: on the Phase 16 baseline
fixture (`backend/evaluation/code_accuracy.py`, 16 tricky Python
cases, 18 expected call edges) the current parser scores call-edge
**precision 0.7333 / recall 0.6111** (TP 11, FP 4, FN 7). The misses
are systematic, not random:

- Module-level assignment aliases (`build_video_item =
  _build_video_item`, or an alias of an imported symbol) produce no
  `CALLS` edge at all — the resolver only knows definitions and
  imports, never assignments.
- `__init__` re-exports produce an edge to the re-export name
  (`pkg.build_video_item`) instead of the definition
  (`pkg.impl.build_video_item`), so `impact_analysis` for the real
  symbol reports zero callers. This is exactly the dogfood miss found
  earlier against veraxi-ymmp, where CodeRabbit was 96.6% precise and
  Veraxi recalled 0 of 28 on `build_video_item` / `_build_video_item`.

A wrong "not reachable" verdict is the dangerous direction for the
Security workbench: a heuristic miss can fold a reachable finding
into the "unreachable" pile. Consumers therefore need to know *how*
an edge was resolved, not just that it exists.

Two compiler-grade sources can raise accuracy where heuristics
cannot:

- **SCIP** (Sourcegraph's index format). Ingestion already exists:
  `backend/ingestion/scip_ingest.py` (`parse_scip_payload` /
  `write_scip_graph`) behind `POST /api/v1/code/ingest-scip`, using
  the conservative `<relative_path>::<descriptor_path>` symbol scheme.
  What does not exist is index *generation* inside Veraxi's own
  tooling, or a rule for which source wins when both describe a file.
- **Linters as claims.** SARIF ingestion already exists
  (`backend/ingestion/sarif.py`, `POST /api/v1/vuln/sarif`). Ruff and
  mypy findings are deterministic claims that should enter through
  that same path — and the AI review passes must never duplicate a
  comment a linter already made on the same file, line range and
  rule category.

Generation cost is the constraint: SCIP indexers (and a live language
server) need a buildable checkout — dependencies installed, generated
code present. The hosted backend ingests repositories it cannot
build, so generation can never happen there. ADR-0005 already
established the execution split this decision reuses: `veraxi-runner`
executes on the user's workstation over an outbound WebSocket
(`backend/sandbox/ws_runner_provider.py`, provider `local_runner`;
ACP subprocesses via `backend/acp/driver.py`), with a scrubbed
environment and no backend secrets.

Earlier internal estimates put post-SCIP retrieval accuracy at
"0.89–0.92". That estimate is **retired**: from this ADR on, accuracy
claims for code intelligence are the measured numbers from the
baseline fixture (and, for security, `evaluation/security_benchmark.py`),
re-run at each phase.

This work is logged as **Phase 16** in `docs/ROADMAP.md`. Phase 15 is
complete and the project is in polish before v1.0; Phase 16 is
explicitly scoped accuracy work behind that log entry, not silent
scope growth. Phases 2–4 of the accuracy plan (linters runtime,
SCIP spike, SCIP production) each carry their own dependency gate and
do not start without Kazuo's approval.

## Decision

1. **SCIP is authoritative where present.** On a file covered by a
   SCIP index, SCIP edges replace AST / tree-sitter guessed edges.
   Files without SCIP coverage keep their heuristic edges. The
   "SCIP wins" rule and the alias/re-export resolution rule live in
   one named location each — no second copy may drift into existence.
2. **Resolution provenance is recorded.** Every code edge carries (or
   will carry, in Phase 4) a resolution property — `scip` or
   `heuristic` — and `impact_analysis` surfaces it, so a
   "not reachable" verdict resting only on heuristic edges is flagged
   as lower confidence instead of presented as proof.
3. **Generation happens in the local runner or CI, never in the
   hosted backend.** A future CLI command (Phase 4, e.g. under
   `backend/cli/`) runs the indexer where the checkout is buildable
   and uploads the result to the existing SCIP route. The backend
   stays JSON-only: `scip print --json` output in, no protobuf
   dependency in the backend.
4. **Live LSP is deferred.** No language server runs in the hosted
   backend, ever. Dart / live-LSP work is a separate future decision
   with its own ADR (Phase 5 of the accuracy plan).
5. **Linters are claims, gated.** When Phase 2 is approved, ruff and
   mypy run on changed files only (argument-list subprocess calls, a
   timeout, failures reported to Sentry without crashing the
   pipeline), their output is converted to SARIF and fed through the
   existing `ingestion/sarif.py` path, behind a flag defaulting to
   off. The de-dupe rule is a pure function: an AI review comment
   that overlaps a linter finding on the same file, line range and
   rule category is dropped. Semgrep stays in CI; running it in the
   runtime is a separate, heavier decision.
6. **No new dependency is added silently.** `scip-python`,
   `protobuf`, semgrep, and promoting ruff/mypy to runtime
   dependencies are each flagged for explicit approval before they
   land, and dependencies are declared only in `pyproject.toml`.
7. **Alias resolution is fixed in the heuristic parser first**
   (Phase 1): module-level assignment aliases and transitive
   `__init__` re-exports resolve to the defining symbol, with
   same-name collision tests proving distinct modules never merge.
   This is the cheapest large share of the measured recall gap and
   needs no new dependency.

## Consequences

- **Positive**: `impact_analysis` stops reporting zero callers for
  re-exported symbols (the dogfood miss); accuracy becomes a measured
  fixture number that each phase must move, not an estimate; SCIP
  adoption has a pre-agreed authority and provenance model, so its
  spike (Phase 3) is judged against preset go/no-go criteria instead
  of argued afterwards.
- **Negative**: Two sources of truth (SCIP and heuristic) can drift;
  the provenance tag and the single "SCIP wins" location are the
  mitigation, and both are test obligations, not conventions. Running
  indexers or linters on untrusted customer code needs sandboxing —
  generation is therefore local-runner/CI only, and any runtime
  linting must be checked against `backend/sandbox/` before it runs
  on uploaded repos.
- **Neutral**: Phase 1 changes only heuristic resolution inside
  `ingestion/code_graph.py`; Neo4j↔Qdrant linking is untouched (code
  nodes carry no Qdrant point IDs — see the `code_graph.py` module
  docstring), Cypher stays parameterized, and `merge_rank.py` is not
  modified.
