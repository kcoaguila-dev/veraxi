# 7. Compiler-Grade Code Intelligence (SCIP, Linters-as-Claims, Resolution Provenance)

Date: 2026-11-25

## Status

Accepted

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

## Phase 2 result (2026-11-25, approved and built)

Kazuo approved all remaining dependency gates on 2026-11-25
("work all phases"). Phase 2 landed as `backend/ingestion/lint_findings.py`:

- `ruff` and `mypy` are now declared as backend **runtime**
  dependencies in `pyproject.toml`. Before this change they were not
  declared there at all — CI pip-installed them ad hoc and
  pre-commit pinned its own copies.
- Ruff runs with `--output-format sarif`; mypy runs with
  `--output json` and its JSON-lines are converted to the same SARIF
  shape. Both run on changed files only, as argument-list
  subprocesses with a timeout; a missing / timed-out / fatally
  failing tool is reported to Sentry and yields no findings instead
  of crashing. Findings persist through the existing
  `ingestion/sarif.py` parse/write path. The whole path is behind
  `LINT_FINDINGS_ENABLED`, default off.
- The de-dupe rule exists as the pure function
  `dedupe_review_comments` with unit tests. It is **not yet wired
  into a live comment stream**: the current review surface (CLI
  `review` → LLM briefing engine) produces free text, not structured
  comments with file/line/category. It wires in when the PR-review
  pipeline (WP5) produces structured comments. The plan's
  measurement — share of AI comments duplicating lint findings over
  10–20 past PRs — cannot be computed honestly from anything in this
  repo (no stored structured review comments exist), so no number is
  quoted for it.

## Phase 3 spike result (2026-11-25): GO, with conditions

Spike tooling lived entirely outside the repo (scratch venv / npm
sandbox under `~/workspace/scip-spike*`); nothing became a repo
dependency. Two premises of the original plan proved wrong, and both
matter:

1. **`scip-python` is not on PyPI** (`pip install scip-python`
   returns 404; general PyPI access verified working). Its official
   distribution is the npm package `@sourcegraph/scip-python`
   (v0.6.8, used here), and `scip print` is the separate Go CLI from
   `sourcegraph/scip` releases (v0.4.0, used here). Any production
   generation step is therefore a Node-distributed tool invoked by
   the CLI/runner — never a Python import.
2. **The shipped SCIP ingest path does not parse real indexes.**
   `scip print --json` emits protobuf-JSON **camelCase** keys
   (`relativePath`, `symbolRoles`, `enclosingRange`, `projectRoot`),
   while `parse_scip_payload` expects snake_case — and every existing
   test fixture is snake_case. A real Veraxi-backend index (311
   documents, 109,675 occurrences) parses through the current code
   to **0 nodes / 0 edges**. With a mechanical camelCase→snake_case
   translation the same payload parses to 27,538 nodes / 36,267
   REFERENCES + 27,227 DEFINES edges. Fixing the parser to accept
   real output is a precondition for Phase 4, not an optional extra.

Measured results (indexer always invoked with `--project-version`,
see failure modes):

| Target | Build | Time | Peak RSS | Index size |
| --- | --- | --- | --- | --- |
| Veraxi backend (311 files) | OK | 51.9 s | ~1.09 GB | 9.0 MB |
| itsdangerous (external) | OK | 4.9 s | ~290 MB | 394 KB |
| markupsafe (external, C ext) | OK | 8.5 s | ~290 MB | 144 KB |
| Constructed hard-cases project | OK | 3.7 s | — | — |
| Fixture cases (16 micro-projects) | 16/16 OK | 2–5 s each | — | — |

Edge comparison (path+name level, through the real
`parse_scip_payload` after key translation):

- **Baseline fixture: AST 18/18, SCIP 14/18.** SCIP misses all three
  assignment-alias cases and the assignment re-export case —
  pyright resolves the alias *variable*, and the reference points at
  that variable, not through it to the function definition. The
  Phase 1 heuristic fix is strictly better here.
- **Constructed hard cases: AST 0/6, SCIP 5/6.** SCIP correctly
  resolves the patterns the AST pass gets wrong: inherited-method
  dispatch (`self.helper()` → base-class definition), `import
  pkg.sub` + `pkg.sub.fn()`, instance-method calls (locally
  constructed and annotation-typed parameters), and a cross-file
  classmethod call. Both miss the dynamic dict-dispatch control, as
  expected. Same-name collisions: SCIP separates them (path-prefixed
  qualified names; on the Veraxi index, 1,291 display names map to
  more than one distinct node, never merged).
- The two sources are **complementary, not dominant**: SCIP wins on
  type-resolved dispatch, the heuristic parser wins on assignment
  aliases. SCIP also produces roughly an order of magnitude more
  nodes than the AST parse (module/`local` pseudo-symbols), a real
  storage/noise cost.

Failure modes observed:

- **Non-git projects crash the indexer** (scip-python 0.6.8,
  `normalizeNameOrVersion` on an undefined version) unless
  `--project-version` is passed. The flag is therefore part of the
  standard generation invocation, not a per-project setup step.
- A target's own `pyproject.toml` can spam pyright TOML parse errors
  (itsdangerous) without failing the build.
- Symbols not defined in the index (missing dependencies, stdlib)
  produce no edges by design in `scip_ingest.py` — under-claiming is
  preserved.
- Indexing the Veraxi monorepo root (Flutter + `packages/`) was not
  attempted; the backend subtree was indexed from its own root.

Verdict against the preset criteria:

- (a) Index builds on ≥80% of sample repos without manual setup:
  **pass** — 4/4 real projects and 16/16 fixture projects, with the
  `--project-version` flag as part of the standard invocation.
- (b) SCIP finds ≥5 correct edges the AST pass gets wrong: **pass,
  exactly at threshold** — 5 on the constructed hard cases. The
  fixture no longer discriminates in SCIP's favour (post-Phase-1 AST
  beats SCIP there), which is stated plainly rather than argued
  around.
- (c) Build time acceptable for CI / local runner: **pass** — ~52 s
  and ~1.1 GB peak for a 311-file backend; seconds for small repos.
  Not acceptable for interactive per-save use, which was never the
  proposal.

**GO for Phase 4**, conditioned on: (1) the parser accepting real
camelCase output (snake_case kept as back-compat); (2) generation
always passing `--project-version`; (3) "SCIP replaces AST" scoped
to the SCIP-covered paths within the same repo partition — the two
qualified-name schemes differ (SCIP `path::descriptor` vs AST dotted
names), so cross-scheme node replacement is not attempted, and the
assignment-alias regression above is the known cost when SCIP
coverage replaces heuristic edges for a file.

## Phase 4 result (2026-11-25, built on the GO above)

- **Parser fix (the precondition).** `parse_scip_payload` now
  normalizes protobuf-JSON camelCase keys to the parser's snake_case
  shape on entry (`_normalize_scip_keys` in `scip_ingest.py`);
  snake_case payloads are unchanged. Regression tests parse a
  camelCase rewrite of the existing fixture to the identical graph,
  plus a verbatim document from a real scip-python run.
- **Generation (local runner / CI only).** `veraxi xray index
  --generate-scip <repo>` (`run_xray_index_generate_scip` in the CLI
  package) runs `scip-python index` (always with
  `--project-version`: the checkout's git HEAD, else `0.0.0`) and
  `scip print --json` on the operator's machine, then uploads via
  the existing `--scip` route. Binaries resolve via
  `VERAXI_SCIP_PYTHON_BIN` / `VERAXI_SCIP_BIN` or PATH. Because
  scip-python is npm-distributed, it is **not** declared in
  `pyproject.toml` — not even as an optional extra: pip cannot
  install it, and a declaration that cannot resolve would be a lie.
  The backend gains no dependency at all in this phase and stays
  JSON-only (no protobuf).
- **SCIP wins, scoped.** `write_scip_graph` now deletes the stored
  nodes (DETACH DELETE, via the existing `_delete_nodes_for_paths`)
  for exactly the files the index covers, within the SCIP
  partition's own `repo_key`, before writing — so a covered file's
  heuristic edges cannot survive next to its SCIP edges, and
  uncovered files keep their heuristic graph untouched. Cross-
  partition replacement is not attempted (the qualified-name
  schemes differ; see the spike condition 3).
- **Resolution provenance.** Provenance is recorded on **nodes**
  (`CodeNode.resolution`, persisted as the `resolution` property —
  `scip` or `heuristic`); this refines Decision 2's "every code
  edge" wording, because the graph writer's edge model carries no
  per-edge properties, while every edge's endpoints live in exactly
  one resolution partition after the scoped replacement above.
  `impact_analysis` now returns additive `resolution` /
  `confidence` fields (plus `confidence_note` when a "no impact"
  or "not found" verdict rests only on heuristic resolution):
  scip-backed = high, mixed = medium, heuristic-only = low.
- **Security benchmark.** `evaluation/security_benchmark.py`
  re-run: 5/6 in this VM, identical before and after Phase 4 — the
  one failing case (`treesitter_polyglot_calls`) is the known
  tree-sitter language-pack environment failure, unrelated to this
  phase; the benchmark's own test records 6/6 as the expectation
  in a correct environment. No recorded standalone baseline file
  exists; the before/after comparison here is the baseline record.
- **Phase 5 revisit note.** The spike strengthens the deferred
  Dart/LSP case in one respect — pyright-grade resolution found
  exactly the dispatch patterns the heuristic parser misses — but
  Dart's indexer maturity is unchanged by anything measured here,
  and the node-volume cost (~10× the AST graph) argues for the
  local-runner-first design when Phase 5 is revisited. No Phase 5
  work was built.
