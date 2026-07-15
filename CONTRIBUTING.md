# Contributing

Thanks for considering contributing to Veraxi. This project is early-stage —
check [docs/ROADMAP.md](docs/ROADMAP.md) to see what phase is active before
starting work.

## Before you start

- For anything beyond a small fix, open an issue first to discuss the
  approach before writing code. This avoids spending time on a PR that goes
  in a direction that doesn't fit.
- Look for issues labeled `good first issue` if you're new to the codebase.

## Development setup

Follow these step-by-step instructions to set up your local development environment.

1. **Clone the repository:**
   ```bash
   git clone https://github.com/kcoaguila-dev/veraxi.git
   cd veraxi
   ```

2. **Run the automated setup:**
   This command will automatically create your `.env` files, build your Python virtual environment, install the `pre-commit` security hooks, and fetch the Flutter dependencies.
   ```bash
   make setup
   ```

3. **Set up your API Key:**
   Open the newly created `backend/.env` file and paste your `GEMINI_API_KEY`.

4. **Start the backend and databases:**
   Spin up Neo4j, Qdrant, and the FastAPI server using Docker.
   ```bash
   make up
   ```

5. **Start the Flutter frontend:**
   Run the app natively on your host machine to get UI hot-reloading.
   ```bash
   cd app
   flutter run
   ```

*(Note: When you are done working, you can stop the databases by running `make down`).*

## Architectural Rules

Veraxi follows strict architectural boundaries that **must** be adhered to:

### Flutter Frontend (Feature-First)
- Every feature lives in `lib/features/<feature_name>/` and must use this internal structure:
  - `data/`: Repositories and API clients. Only this layer talks to the backend (via `core/mcp_client`).
  - `view_models/`: Riverpod providers (business logic).
  - `views/`: Flutter widgets (rendering only).
- **Dependency Flow:** Dependency strictly flows inwards: `views` → `view_models` → `data` → `core/mcp_client`.
- `views/` never imports `core/mcp_client` or backend code directly. They can only import from `view_models/`.

### Python Backend (Pipeline-Oriented)
- **Dependency Flow:** `mcp_server/tools` → `retrieval` → `storage`.
- `mcp_server/tools/*` may call `retrieval/` and `storage/`, but never the reverse.
- `ingestion/*` writes directly to `storage/`.
- `storage/` clients must never import anything from `retrieval/` or `mcp_server/`.
- **Query Building:** Never build Cypher queries via string concatenation with user input — use parameterized queries.
- **Merge/Ranking:** `retrieval/merge_rank.py` is the single source of truth for combining graph + vector results. Do not duplicate this logic anywhere.
- **Node Linking:** Every Neo4j node written during ingestion must store its corresponding Qdrant point ID, and vice versa.

## Tests

- Python: `pytest` from `backend/`
- Flutter: `flutter test` from `app/`
- Both run automatically in CI on every PR.
- Any change to `merge_rank.py`, ingestion linking logic, or query construction requires a test in `backend/tests/`.
- Never weaken or skip existing assertions to make a test pass.

## Pull requests

- Keep PRs scoped to one concern where possible.
- Make sure tests pass locally before opening a PR.
