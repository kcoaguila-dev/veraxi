#!/usr/bin/env bash
# Bring the Veraxi stack up in this codespace and print the URLs to open.
#
# Topology (base compose + codespaces override, profile "ui", no Caddy):
#   neo4j :7474/:7687 · qdrant :6333 · redis :6379 ·
#   backend :8000 · web (Flutter/nginx) :8080
#
# The web build needs the backend's public URL as its API_URL dart-define,
# and the backend needs the web origin in CORS_ORIGINS. Inside Codespaces
# both are derived from $CODESPACE_NAME; outside Codespaces (plain local
# devcontainer) they fall back to localhost.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /workspaces/veraxi)"

if [ -n "${CODESPACE_NAME:-}" ]; then
  API_PUBLIC="https://${CODESPACE_NAME}-8000.app.github.dev"
  WEB_PUBLIC="https://${CODESPACE_NAME}-8080.app.github.dev"
else
  API_PUBLIC="http://localhost:8000"
  WEB_PUBLIC="http://localhost:8080"
fi

# Backend CORS: allow this session's web origin (plus local dev origins).
# Rewritten on every host-up so a resumed codespace stays correct.
if grep -q '^CORS_ORIGINS=' backend/.env; then
  sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=\"${WEB_PUBLIC},http://localhost:8080,http://localhost:3000\"|" backend/.env
else
  echo "CORS_ORIGINS=\"${WEB_PUBLIC},http://localhost:8080,http://localhost:3000\"" >> backend/.env
fi

export NEO4J_PASSWORD="${NEO4J_PASSWORD:-changeme_local_password}"
export WORKER_MODE=inline
export AUTH_ENABLED=false
export API_URL="${API_PUBLIC}/api"

echo "== building and starting the stack (first run: several minutes) =="
docker compose -f docker-compose.yml -f docker-compose.codespaces.yml \
  --profile ui up -d --build neo4j qdrant redis backend web

echo "== waiting for the backend =="
for i in $(seq 1 60); do
  if curl -sf http://localhost:8000/docs >/dev/null 2>&1; then echo "backend up"; break; fi
  sleep 5
done
curl -sf http://localhost:8000/docs >/dev/null 2>&1 || {
  echo "backend did not come up — last log lines:"; docker compose logs --tail 40 backend; exit 1; }

cat <<EOF

==============================================================
 Veraxi test instance is up

   Web app (open this on your phone):  ${WEB_PUBLIC}
   API docs:                           ${API_PUBLIC}/docs
   Neo4j Browser:                      https://${CODESPACE_NAME:-localhost}-7474.app.github.dev (local: http://localhost:7474)

 Forwarded ports are PRIVATE by default (only your GitHub login
 can open them) and stable for the life of this codespace.
 Stop the stack with .devcontainer/host-down.sh, and stop the
 codespace itself when done — free quota is 120 core-hours/month
 (30 h on this 4-core size).
==============================================================
EOF
