#!/bin/bash
set -e

echo "======================================"
echo "Starting True E2E Test Pipeline..."
echo "======================================"

# 1. Start isolated Redis for E2E tests
echo "-> Starting temporary Redis container (port 6380)..."
docker rm -f veraxi_e2e_redis 2>/dev/null || true
docker run -d --name veraxi_e2e_redis -p 6380:6379 redis

# 2. Setup User in Supabase
echo "-> Ensuring E2E test user exists in Supabase..."
cd backend
.venv/bin/python3 tests/setup_e2e_user.py
cd ..

# 3. Start Backend locally on a test port
echo "-> Starting Backend API on port 8001..."
export AUTH_ENABLED=true
export REDIS_URL="redis://localhost:6380"
export PORT=8001
export OPENAI_API_KEY="dummy_key_for_e2e"
export OPENAI_BASE_URL="http://127.0.0.1:8002"

# Run the mock LLM server in the background
cd backend
.venv/bin/uvicorn tests.mock_llm_server:app --port 8002 &
MOCK_LLM_PID=$!

# Run the backend in the background
.venv/bin/uvicorn api_gateway:app --port $PORT &
BACKEND_PID=$!
cd ..

# Wait for backend to start
echo "-> Waiting for backend to initialize..."
sleep 5

# 4. Run Flutter E2E Test
echo "-> Running Flutter Integration Test..."
cd app
set +e # Don't exit immediately if test fails so we can teardown
xvfb-run /home/ubuntu/development/flutter/bin/flutter test integration_test/true_e2e_test.dart --dart-define=API_URL=http://localhost:$PORT/api
TEST_EXIT_CODE=$?
set -e
cleanup() {
  echo "======================================"
  echo "-> Tearing down E2E environment..."
  kill $BACKEND_PID 2>/dev/null || true
  kill $MOCK_LLM_PID 2>/dev/null || true
  docker rm -f veraxi_e2e_redis >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 5. Result
if [ $TEST_EXIT_CODE -eq 0 ]; then
  echo "✅ E2E Pipeline finished SUCCESSFULLY."
else
  echo "❌ E2E Pipeline FAILED with code $TEST_EXIT_CODE."
fi

exit $TEST_EXIT_CODE
