# Instructions for AI coding agents

This file guides AI tools (Claude Code, Cursor, Copilot, etc.) working on
this repo. Follow the rules below exactly — they're deliberate constraints,
not suggestions, and violating them is treated as a bug even if the code
otherwise works.

## Project shape

- `backend/` — Python. Organized by responsibility, not feature-first,
  since it's one shared pipeline (ingest → store → retrieve → serve),
  not multiple independent features. See `docs/architecture.md`.
- `app/` — Flutter, feature-first. Every feature is a self-contained folder
  under `lib/features/<feature_name>/` with exactly this internal structure:
```text
features/<feature_name>/
├── data/        # repository + API client — talks to core/mcp_client
├── view_models/ # Riverpod providers — app/business logic
└── views/       # widgets — rendering only, no logic
```
New features copy this exact pattern. Don't invent a different internal
structure per feature.

## Frontend dependency direction (clean architecture boundary)

Dependencies only point one way — inward, never sideways or backward:
```text
views  →  view_models  →  data (repository)  →  core/mcp_client
```
- `views/` may only import from `view_models/` in the same feature. Never
  `data/`, `core/mcp_client`, or backend code directly.
- `view_models/` may only import from `data/` in the same feature, never
  `core/mcp_client` directly.
- Only `data/` is allowed to talk to `core/mcp_client`.
- Features never import from other features' `data/` or `view_models/`
  directly — shared logic goes in `core/`.

This is enforced by `import_lint` (see `analysis_options.yaml`), not just an
honor system — a violation should fail `dart analyze` / CI, not rely on
manual review to catch it.

## Backend dependency direction

The backend is a pipeline, organized by responsibility, not feature-first.
Dependencies flow one way:
```text
mcp_server/tools  →  retrieval  →  storage
ingestion         →  storage
```
- `mcp_server/tools/*` may call into `retrieval/` and `storage/`, never the
  reverse. `retrieval/` and `storage/` must not import from `mcp_server/`.
- `ingestion/*` writes directly to `storage/` — it does not go through
  `retrieval/` (retrieval is for reads/queries, not writes).
- `storage/` clients (`neo4j_client.py`, `qdrant_client.py`) must not import
  anything from `retrieval/` or `mcp_server/`.
- `config.py` may be imported anywhere; nothing should hardcode values that
  belong in it.

This is enforced by `import-linter` (see `.importlinter` config), not just an
honor system.

## Hard rules

- Never build Cypher queries via string concatenation with user input — use
  parameterized queries. Security requirement, not a style preference.
- `retrieval/merge_rank.py` is the single place graph + vector results are
  combined. Don't duplicate merge/ranking logic elsewhere.
- Every Neo4j node written during ingestion must store its corresponding
  Qdrant point ID, and vice versa. Breaking this link is a critical bug.
- Don't add new top-level folders or restructure without checking
  `docs/architecture.md` first.
- Don't add a new dependency (Python package or Dart pub package) without
  flagging it first — this is a decision, not a default.
- Don't extract a shared function/class until there are two real callers.
    A single caller with an eye toward "future reuse" is not a second caller.
- When you do extract shared logic (like merge_rank.py), it lives in one
  named location — don't let a second copy drift into existence elsewhere.

## Testing expectations

- Any change to `merge_rank.py`, ingestion linking logic, or query
  construction needs a corresponding test in `backend/tests/`.
- Run `pytest` (backend) and `flutter test` (app) before considering a
  change complete.
- Never weaken, skip, or loosen an assertion in an existing test to make it
  pass. If a test fails, fix the underlying code, or flag that the test
  itself may be wrong and explain why — don't silently make the test less
  strict.

## Current priority

Check `docs/ROADMAP.md` for the active phase before starting new work.