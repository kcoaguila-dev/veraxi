#!/bin/bash
set -e

VM_NAME="veraxi-staging"
REMOTE_DIR="veraxi"
MAX_RETRIES=${MAX_RETRIES:-30}

# Automatically extract the zone from Terraform vars to make this script zero-config
ZONE=$(grep '^zone' infra/terraform.tfvars | awk -F '"' '{print $2}')
if [ -z "$ZONE" ]; then
    ZONE="asia-northeast2-a" # Default fallback
fi

echo "Starting Veraxi GCP Staging Test Workflow in zone: $ZONE..."

# 1. Sync local code to VM
echo "Syncing local code to GCP..."
gcloud compute ssh $VM_NAME --zone=$ZONE --command="mkdir -p ~/$REMOTE_DIR"

# Using tar over SSH is the fastest and most robust way to sync while excluding heavy/temp folders
tar \
  --exclude='.venv' \
  --exclude='app/.dart_tool' \
  --exclude='app/build' \
  --exclude='backend/.pytest_cache' \
  --exclude='backend/__pycache__' \
  --exclude='.git' \
  -czf - . | gcloud compute ssh $VM_NAME --zone=$ZONE --command="cd ~/$REMOTE_DIR && tar -xzf -"

# 2. Run tests remotely inside Docker
echo "Running tests on GCP..."
gcloud compute ssh $VM_NAME --zone=$ZONE --command="
  set -e
  cd ~/$REMOTE_DIR
  
  echo 'Running Flutter tests in ephemeral container...'
  docker build -t veraxi-frontend-test -f app/Dockerfile.test app/
  docker run --rm veraxi-frontend-test
  
  echo 'Starting backend services natively via Docker Compose...'
  # Cleanup hook: Guarantee the containers are destroyed even if tests fail
  trap 'echo \"Cleaning up Staging VM state...\" && docker compose down' EXIT
  
  docker compose up -d --build
  
  echo 'Waiting for backend API to be ready...'
  retries=$MAX_RETRIES
  while ! curl -s http://localhost:8000/health > /dev/null; do
    retries=\$((\$retries - 1))
    if [ \$retries -le 0 ]; then
      echo 'Timeout waiting for API gateway.'
      exit 1
    fi
    sleep 2
  done
  
  echo 'Running pytest inside the backend container...'
  docker compose exec -T backend bash -c \"cd backend && pip install .[dev] && USE_TESTCONTAINERS=false pytest\"
"

echo "Workflow completed and Staging VM cleaned up successfully!"
