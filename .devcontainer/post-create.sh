#!/usr/bin/env bash
# Veraxi Codespaces post-create:
#  1. Wait for docker-in-docker to be ready.
#  2. Create backend/.env (test-instance values) if it does not exist.
#     The backend service in docker-compose.yml requires this env_file.
#  3. Pre-pull the third-party service images so the first `host-up.sh`
#     only has to build the backend and web images.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /workspaces/veraxi)"

echo "== waiting for docker =="
for i in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then echo "docker ready"; break; fi
  sleep 2
done
docker info >/dev/null 2>&1 || { echo "docker not ready — try again in a minute"; exit 1; }

echo "== backend/.env =="
if [ ! -f backend/.env ]; then
  cp backend/.env.example backend/.env
  # Single-user test instance (same choices as the Colab boot notebook):
  #  - AUTH_ENABLED=false   documented local bypass in .env.example
  #  - WORKER_MODE=inline   no separate arq worker container
  #  - INGESTION_PROFILE=lite  fast cold start (220MB MiniLM)
  #  - NEO4J_PASSWORD aligned with the compose neo4j service default
  #    (NEO4J_AUTH=neo4j/changeme_local_password). NOTE: backend/.env.example
  #    ships NEO4J_PASSWORD=neo4j_password_123, which does NOT match the
  #    compose default — under compose, the `environment:` block wins over
  #    env_file, so the example value is a latent trap for non-compose runs.
  sed -i \
    -e 's|^AUTH_ENABLED=.*|AUTH_ENABLED=false|' \
    -e 's|^WORKER_MODE=.*|WORKER_MODE=inline|' \
    -e 's|^INGESTION_PROFILE=.*|INGESTION_PROFILE=lite|' \
    -e 's|^NEO4J_PASSWORD=.*|NEO4J_PASSWORD=changeme_local_password|' \
    -e 's|^LANGCHAIN_TRACING_V2=.*|LANGCHAIN_TRACING_V2=false|' \
    -e 's|^SEARXNG_URL=.*|SEARXNG_URL=|' \
    backend/.env
  # Your BYOK key: add LLM_API_KEY (and optionally LLM_BASE_URL /
  # LLM_MODEL_NAME) to backend/.env before starting the stack.
  echo "backend/.env created — add your LLM_API_KEY to it, then run .devcontainer/host-up.sh"
else
  echo "backend/.env already exists, leaving it untouched"
fi

echo "== pre-pulling service images =="
docker compose pull neo4j qdrant redis || true
echo "post-create done"
