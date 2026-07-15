#!/bin/bash
set -e

VM_NAME="veraxi-staging"
REMOTE_DIR="veraxi"

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
  cd ~/$REMOTE_DIR && \
  echo 'Running Flutter tests in ephemeral container...' && \
  docker build -t veraxi-frontend-test -f app/Dockerfile.test app/ && \
  docker run --rm veraxi-frontend-test && \
  echo 'Starting backend services...' && \
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "\$PWD:\$PWD" -w "\$PWD" docker/compose:latest up -d --build && \
  echo 'Waiting for services to be ready...' && \
  sleep 5 && \
  echo 'Running pytest inside the backend container...' && \
  docker exec veraxi_backend_1 bash -c \"cd backend && pip install -e .[dev] && USE_TESTCONTAINERS=false pytest\"
"

echo "Workflow completed!"
