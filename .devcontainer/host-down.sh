#!/usr/bin/env bash
# Stop the Veraxi stack. Data volumes (neo4j_data, qdrant_data, redis_data)
# are kept, so indexes survive a codespace stop/start. Add --wipe to delete
# the volumes too and return to a true cold start.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /workspaces/veraxi)"

ARGS=""
if [ "${1:-}" = "--wipe" ]; then ARGS="-v"; fi
docker compose -f docker-compose.yml -f docker-compose.codespaces.yml \
  --profile ui down $ARGS
echo "stack stopped${ARGS:+ (volumes wiped)}"
