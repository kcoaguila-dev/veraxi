#!/bin/bash
set -e

# Change to project root
cd "$(dirname "$0")/.."

echo "Starting Veraxi API Gateway..."

# Export python path
export PYTHONPATH=$(pwd)

# Activate virtual environment
source backend/.venv/bin/activate

# Start the uvicorn server
uvicorn backend.api_gateway:app --host 0.0.0.0 --port 8000 --reload
