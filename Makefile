.PHONY: setup up down run run-backend test test-gcp seed lint format inspect-mcp clean help

help:
	@echo "Available commands:"
	@echo "  make setup        - Copies .env files, sets up Python venv, pre-commit, and Flutter deps"
	@echo "  make up           - Starts the backend and databases via Docker Compose"
	@echo "  make down         - Stops all Docker containers"
	@echo "  make seed         - Seeds local Neo4j & Qdrant with synthetic multi-hop test data"
	@echo "  make lint         - Runs ruff check on Python and flutter analyze on Flutter"
	@echo "  make format       - Auto-formats Python (ruff) and Flutter (dart format)"
	@echo "  make test         - Runs backend and frontend tests locally"
	@echo "  make test-gcp     - Syncs code and runs the test suite on the GCP Staging VM"
	@echo "  make inspect-mcp  - Launches interactive MCP inspector for /sse endpoint"
	@echo "  make run-backend  - Starts the FastAPI backend natively (outside Docker) with hot-reload"
	@echo "  make run          - Starts the Docker backend and immediately launches the Flutter desktop app"
	@echo "  make clean        - Removes virtual environments and cached build files"

setup:
	@echo "--- Copying environment variables ---"
	cp -n backend/.env.example backend/.env || true
	cp -n app/.env.example app/.env || true
	@echo "--- Setting up Python backend and pre-commit ---"
	cd backend && python3 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]" pre-commit && pre-commit install
	@echo "--- Setting up Flutter frontend ---"
	cd app && flutter pub get
	@echo ""
	@echo "Setup complete! Please add your GEMINI_API_KEY and SENTRY_DSN to backend/.env"
	@echo "Then run 'make up' followed by 'make seed' to start."

run-backend:
	@echo "--- Starting backend locally with hot-reload ---"
	PYTHONPATH=. backend/.venv/bin/uvicorn backend.api_gateway:app --reload --port 8000

up:
	@echo "--- Starting Veraxi stack ---"
	docker compose up -d
	@echo ""
	@echo "Veraxi services are online:"
	@echo "  • Backend API & Docs : http://localhost:8000/docs"
	@echo "  • Neo4j Browser      : http://localhost:7474 (user: neo4j, pass: changeme_local_password)"
	@echo "  • Qdrant Dashboard   : http://localhost:6333/dashboard"
	@echo "  • SearXNG Search     : http://localhost:8080"
	@echo ""
	@echo "Run 'make seed' to populate initial graph entities and vector embeddings."

down:
	@echo "--- Stopping Veraxi stack ---"
	docker compose down

seed:
	@echo "--- Seeding local Neo4j & Qdrant with synthetic GraphRAG data ---"
	PYTHONPATH=. backend/.venv/bin/python -m backend.scripts.seed_dev_data --clean

lint:
	@echo "--- Linting Python and Flutter ---"
	ruff check backend packages/veraxi-cli
	cd app && flutter analyze

format:
	@echo "--- Formatting Python and Flutter ---"
	ruff format backend packages/veraxi-cli
	cd app && dart format .

inspect-mcp:
	@echo "--- Launching Model Context Protocol (MCP) Inspector ---"
	npx @modelcontextprotocol/inspector http://localhost:8000/sse

run:
	@echo "--- Starting full Veraxi stack locally ---"
	docker compose down
	docker compose up -d --build
	@echo "--- Launching Flutter Desktop App ---"
	cd app && flutter run -d linux

test:
	@echo "--- Running backend tests ---"
	cd backend && . .venv/bin/activate && pytest
	@echo "--- Running frontend tests ---"
	cd app && flutter test

test-gcp:
	@echo "--- Syncing and testing on GCP Staging ---"
	./scripts/test_on_gcp.sh

clean:
	@echo "--- Cleaning up environment ---"
	rm -rf backend/.venv
	rm -rf backend/.pytest_cache
	rm -rf backend/__pycache__
	cd app && flutter clean
