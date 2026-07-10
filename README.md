# Veraxi

A chat application that combines a knowledge graph (Neo4j) and vector search
(Qdrant) to give an LLM tool-based access to both relational and semantic
context, exposed through MCP.

## Status

Early development. See [docs/ROADMAP.md](docs/ROADMAP.md) for current phase
and what's next.

## Architecture

See [docs/architecture.md](docs/architecture.md) for a diagram and breakdown
of the backend (Python + MCP) and frontend (Flutter) structure.

## Stack

- **Backend:** Python, MCP server, Neo4j, Qdrant
- **Frontend:** Flutter (Dart), Riverpod

## Setup

1. Copy `.env.example` to `.env` in both `backend/` and `app/`, fill in values
2. `docker-compose up` to start Neo4j and Qdrant locally
3. Backend: `cd backend && pip install -e .` *(instructions will expand as the
   backend takes shape)*
4. Frontend: `cd app && flutter pub get && flutter run`

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).