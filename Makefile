.PHONY: setup up down test test-gcp clean help

help:
	@echo "Available commands:"
	@echo "  make setup    - Copies .env files, sets up Python venv, pre-commit, and Flutter deps"
	@echo "  make up       - Starts the backend and databases via Docker Compose"
	@echo "  make down     - Stops all Docker containers"
	@echo "  make test     - Runs backend and frontend tests locally"
	@echo "  make test-gcp - Syncs code and runs the test suite on the GCP Staging VM"
	@echo "  make run-backend - Starts the FastAPI backend natively (outside Docker) with hot-reload"
	@echo "  make clean    - Removes virtual environments and cached build files"

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
	@echo "Then run 'make up' to start the servers."

run-backend:
	@echo "--- Starting backend locally with hot-reload ---"
	cd backend && . .venv/bin/activate && uvicorn api_gateway:app --reload --port 8000

up:
	@echo "--- Starting Veraxi stack ---"
	docker compose up -d --build

down:
	@echo "--- Stopping Veraxi stack ---"
	docker compose down

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
