# 8. Dart & Flutter Code Intelligence (SCIP-Dart, Tree-Sitter Fallback, Live LSP Deferral)

Date: 2026-11-27

## Status

Proposed (awaiting merge with Phase 5D slices)

## Context

[ADR-0007](0007-compiler-grade-code-intelligence.md) brought compiler-grade SCIP indexing (`scip-python`), resolution provenance (`CodeNode.resolution`), and confidence reporting (`impact_analysis`) to Python, while deferring **Phase 5 (Dart / live LSP)** to its own ADR.

Measuring `parse_repo(Path("app"))` against `main` (`c5065536`, 360 `.dart` files on disk, 341 parsed) established the baseline gap:

- **Dart `CALLS` edges:** `0` (`TP=0, FP=0, FN=23`, recall `0.0000`, precision `null` on the 17-case Phase 5A fixture `backend/evaluation/dart_code_accuracy.py`).
- **Resolved Dart `IMPORTS`:** `0 / 1,838` (targets are raw URI strings like `package:veraxi_app/...` rather than `CodeModule.qualified_name`).
- **Resolved Dart `INHERITS`:** `0 / 489` (targets are unqualified class names rather than `Class.qualified_name`).
- **Root cause in `backend/ingestion/code_graph.py`:** `tree-sitter-dart` emits `function_signature`/`method_signature` and `function_body` as siblings (so bodies are never walked inside `Function` scope), and Dart call sites use `identifier` + `selector -> argument_part` rather than `call_expression`.

In Phase 5B, two tracks were benchmarked against the 5A fixture and `app/`:

1. **Track 1 — Batch SCIP (`scip_dart 1.8.1` + `scip v0.10.0` → `parse_scip_payload`):**
   - Builds `17/17` fixture cases and `app/` (`341` documents) in **89.75 s** at **1.995 GB** peak RSS (`15 MB` `.scip` → `27 MB` JSON → **`5,357` nodes / `16,043` edges**, `2.68%` of `MAX_INGEST_NODES`).
   - Achieves **0.9565 recall (`22/23`)** on the 5A fixture with **0** wrong-target call resolutions (`0.5500` raw precision only because `scip_ingest.py` emits `REFERENCES` for types, fields, and import prefixes as well as calls; `1` FN on `part-and-part-of`).
   - Fails fast (`exit 1`) when `.dart_tool/package_config.json` is absent; silently omits symbols from missing `.g.dart` files.
2. **Track 2 — Live LSP (`dart language-server --protocol=lsp`, host-side stdio):**
   - Resolves `23/23` semantic calls on the 5A fixture (`0.9130` raw before constructor name normalization) and runs at `776.1 MB` RSS on `app/` with `50–63 ms` warm queries.
   - However, cold `textDocument/references` on a `lib/main.dart` symbol **timed out at 30 s** during initial workspace analysis (`6.92 s` on a smaller symbol), and `veraxi-runner` (`runner/veraxi_runner/local_exec.py`, `backend/sandbox/ws_runner_provider.py`) currently only supports stateless request/response RPCs defaulting to `python:3.12-slim` Docker containers.

## Decision

1. **Adopt `scip_dart` for compiler-grade Dart indexing (local CLI / CI only, never hosted backend).**
   Extend `veraxi xray index --generate-scip` (`packages/veraxi-cli/src/veraxi/cli/code_intel.py`) to support Dart (`--lang dart` or auto-detected via `pubspec.yaml`), running `scip_dart` + `scip print --json` on the operator's machine and uploading via the existing `POST /api/v1/code/ingest-scip` endpoint with canonical `repo_key`. Require a preflight check for `.dart_tool/package_config.json` so missing `pub get` fails with an actionable message (`Run 'flutter pub get' or 'dart pub get' first`).
2. **No new backend or app dependency.**
   `scip_dart` (`dart pub global activate scip_dart`) and `scip` (`sourcegraph/scip` / `scip-code/scip` releases) are operator-installed CLI tools resolved via `VERAXI_SCIP_DART_BIN` / `VERAXI_SCIP_BIN` / `PATH` (and `~/.pub-cache/bin/scip_dart`), never declared in `backend/pyproject.toml` or `app/pubspec.yaml`. The backend remains JSON-only (no `protobuf` dependency).
3. **Fix the zero-dependency `tree-sitter-dart` fallback in `backend/ingestion/code_graph.py`.**
   Hosted and GitHub-App repositories cannot run `scip_dart` server-side. Pairing `function_signature`/`method_signature` with `function_body`, resolving Dart `selector -> argument_part` calls, and resolving relative/`package:` imports + `INHERITS` within the parsed tree eliminates the `0`-edge Dart blind spot for hosted users with zero new dependencies.
4. **Reuse `CodeNode.resolution` (`"scip" | "heuristic"`) — no parallel provenance field.**
   Dart SCIP uploads reuse `write_scip_graph` (`resolution="scip"`, scoped replacement per covered file) and `_resolution_confidence` in `backend/retrieval/code_queries.py`. Do not introduce a separate `graph_source` property.
5. **Defer live LSP (`dart language-server`) in `veraxi-runner`.**
   Persistent stateful LSP sidecar management in `veraxi-runner` / `WsRunnerProvider` is deferred to a future ADR; batch SCIP + improved tree-sitter fallback close the Neo4j Dart accuracy gap without adding persistent runner-process complexity.
6. **Known static limits remain explicitly documented.**
   `MethodChannel` platform calls and string-based routing (e.g., `go_router` paths) are invisible to both `scip_dart` and `tree-sitter-dart` and are never guessed.

## Consequences

- **Positive:** Dart repositories indexed via CLI/CI gain compiler-grade `REFERENCES` (`0.9565` recall on the 5A fixture) and `resolution="scip"` / `confidence="high"` in `impact_analysis`; hosted Dart repos gain real `CALLS`, `IMPORTS`, and `INHERITS` edges via `tree-sitter-dart` with zero new dependencies.
- **Negative:** `scip_dart` requires `flutter pub get` / `dart pub get` (and generated `.g.dart` files) on the indexing machine, takes ~90 s / ~2 GB RSS on `app/`, and misses `part`-file links in some synthetic cases (`part-and-part-of`).
- **Neutral:** Retrieval ranking (`merge_rank.py`), Python AST/SCIP pipelines, and Flutter UI are untouched.
