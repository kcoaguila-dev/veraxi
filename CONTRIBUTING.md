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

1. Copy `.env.example` to `.env` in both `backend/` and `app/`
2. `docker-compose up` to start Neo4j and Qdrant locally
3. Backend: `cd backend && pip install -e .`
4. Frontend: `cd app && flutter pub get`

## Code boundaries

- `views/` (Flutter) never imports `mcp_client` or backend code directly —
  always through `view_models/` and `data/`.
- `retrieval/merge_rank.py` is the only place graph and vector results get
  combined — don't scatter merge logic elsewhere.
- Neo4j nodes and Qdrant points created during ingestion must stay linked by
  ID in both directions — treat breaking this link as a critical bug.
- Never string-concatenate user input into a Cypher query — use parameterized
  queries always.

## Tests

- Python: `pytest` from `backend/`
- Flutter: `flutter test` from `app/`
- Both run automatically in CI on every PR.

## Pull requests

- Keep PRs scoped to one concern where possible.
- Make sure tests pass locally before opening a PR.