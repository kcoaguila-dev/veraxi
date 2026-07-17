# Instructions for AI coding agents

This file guides AI tools (Claude Code, Cursor, Copilot, etc.) working on
this repo. Follow the rules below exactly — they're deliberate constraints,
not suggestions, and violating them is treated as a bug even if the code
otherwise works.

## Agent Behavior & Scope Discipline

- **Scope Containment**: Never refactor code outside the explicit scope of the user's request. If you encounter unrelated technical debt or poor naming conventions, flag it to the user in your response rather than silently changing it.
- **Preserve Context**: NEVER delete existing docstrings or inline comments when modifying a file. You must actively preserve the documentation written by human developers.
- **No Placeholders**: Never write `# TODO: implement`, `pass`, or leave mocked data in a finished feature unless explicitly instructed to build a stub. Implement the full logic.
- **Read Before Writing**: If a task involves architecture, state management, or infrastructure, you MUST search and read the `docs/adr/` (Architectural Decision Records) directory before proposing a plan.

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

## Environment & Dependency Management

- **Source of Truth**: All backend dependencies MUST be declared in `pyproject.toml`. All frontend dependencies MUST be declared in `pubspec.yaml`. Do not rely solely on imperative `pip install` or `flutter pub add` commands without updating these files.
- **PEP 668 Virtual Environment Enforcement**: Never use global `pip` or global Python interpreters. The host OS (Debian/Ubuntu) enforces PEP 668 ("externally-managed-environment"). Always execute commands explicitly through the virtual environment (e.g., `backend/.venv/bin/pip` or `backend/.venv/bin/pytest`).
- **Secrets Management**: Never hardcode credentials, URLs, or DSNs in the source code. Backend secrets must be loaded via `os.environ` and documented in `.env.example`. Frontend secrets must be passed via `--dart-define` and retrieved using `String.fromEnvironment`.
- **IDE State Synchronization**: If you add a new dependency, you must account for the IDE's Language Server caching. If an import fails immediately after installation, do not assume the code is broken; inform the user to reload the Language Server.

## Code Quality & CodeScene Constraints

This project adheres to a strict "Zero-Warning" policy in CodeScene to prevent "Bumpy Road" technical debt. All agents MUST follow these structural rules:
- **Zero Cognitive Complexity Tolerance**: Break down monolithic logic. If a function requires deep nesting (e.g., a `for` loop inside an `if` inside a `try`), you must extract the inner logic into a well-named private helper function.
- **Single Responsibility Helpers**: Functions should do one thing. If you are doing entity validation, looping, and data transformation in one block, extract the validation.
- **Fail Fast & Guard Clauses**: Avoid deep `if/else` blocks. Return early to keep the main execution path at the lowest indentation level possible.
- **No Linter/Analyzer Warnings**: Code MUST compile cleanly without Dart Analyzer or Pyright warnings. Do not leave "experimental feature" warnings or unused variables.

## UI & Aesthetics (Flutter)

- **Premium Design Required**: Never deliver generic, unstyled Material widgets. All UIs must feel premium, modern, and highly polished.
- **Micro-animations**: Interactions (hovering, tapping, loading) must include subtle animations or transitions. Static, rigid UIs are unacceptable.
- **Styling**: Use harmonious color palettes (avoid plain red/blue/green), sleek dark modes if applicable, smooth gradients, and modern typography (e.g., Google Fonts like Inter or Roboto). Do not just use browser/device defaults.

## Logging & Observability

- **No Print Statements**: Never use `print()` for production logic. In Python, use `logging.getLogger(__name__)`. In Dart, use `debugPrint()` or the designated logging framework.
- **Sentry Traceability**: If catching an exception that shouldn't crash the app, ensure it is still reported to Sentry via `sentry_sdk.capture_exception(e)` (Python) or `Sentry.captureException(e)` (Dart) rather than silently swallowing it.

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
