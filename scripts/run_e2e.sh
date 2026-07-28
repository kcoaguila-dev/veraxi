#!/bin/bash
set -e

echo "🚀 Starting E2E Backend Stack..."
docker compose -p veraxi-test -f docker-compose.e2e.yml up -d --build

echo "⏳ Waiting for backend to be ready..."
# We can poll the health endpoint
until curl -s http://localhost:8000/api/health > /dev/null; do
    echo "Waiting for backend..."
    sleep 2
done
echo "✅ Backend is ready!"

echo "📱 Running Flutter Integration Tests for Web..."
cd app

# Start chromedriver in the background
chromedriver --port=4444 &
CHROMEDRIVER_PID=$!

flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/chat_flow_test.dart \
  -d web-server \
  --dart-define=API_URL=http://localhost:8000/api
TEST_EXIT_CODE=$?

# Kill chromedriver
kill $CHROMEDRIVER_PID

cd ..

if [ $TEST_EXIT_CODE -ne 0 ]; then
  echo "❌ E2E Tests Failed!"
  echo "Printing backend logs:"
  docker compose -p veraxi-test -f docker-compose.e2e.yml logs backend
  echo "Printing mock server logs:"
  docker compose -p veraxi-test -f docker-compose.e2e.yml logs mock-llm-server
else
  echo "🎉 E2E Tests Passed!"
fi

echo "🧹 Tearing down E2E Backend Stack..."
docker compose -p veraxi-test -f docker-compose.e2e.yml down -v

exit $TEST_EXIT_CODE
