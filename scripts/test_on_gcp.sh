#!/bin/bash
set -e

VM_NAME="veraxi-staging"
REMOTE_DIR="veraxi"

echo "Starting Veraxi GCP Staging Test Workflow..."

# 1. Sync local code to VM
echo "Syncing local code to GCP..."
gcloud compute ssh $VM_NAME --command="mkdir -p ~/$REMOTE_DIR"

# Using tar over SSH is the fastest and most robust way to sync while excluding heavy/temp folders
tar \
  --exclude='.venv' \
  --exclude='app/.dart_tool' \
  --exclude='app/build' \
  --exclude='backend/.pytest_cache' \
  --exclude='backend/__pycache__' \
  --exclude='.git' \
  -czf - . | gcloud compute ssh $VM_NAME --command="cd ~/$REMOTE_DIR && tar -xzf -"

# 2. Run tests remotely
echo "Running tests on GCP..."
gcloud compute ssh $VM_NAME --command="
  cd ~/$REMOTE_DIR && \
  docker compose up -d && \
  cd backend && \
  if [ ! -d '.venv' ]; then \
    echo 'Setting up Python virtual environment...'; \
    python3 -m venv .venv; \
  fi && \
  source .venv/bin/activate && \
  echo 'Ensuring dependencies are up to date...' && \
  pip install -e '.[dev]' > /dev/null 2>&1 && \
  pytest
"

echo "Workflow completed!"
