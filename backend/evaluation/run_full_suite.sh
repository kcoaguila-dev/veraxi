#!/bin/bash

# Master script to run the full GraphRAG evaluation suite on the official dataset

set -e

WORKSPACE_DIR="/home/ubuntu/src/ai/veraxi"
cd "$WORKSPACE_DIR"

echo "1. Generating full official benchmark corpus (2,062 questions)..."
backend/.venv/bin/python backend/evaluation/generate_benchmark.py --dataset graphrag_bench --samples 0

echo "2. Clearing previous benchmark tenant data from Qdrant and Neo4j..."
cat << 'EOF' > backend/evaluation/clear_benchmark_data.py
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient

tenant = "benchmark"
config = get_config()

# Clear Qdrant
client_wrapper = QdrantStorageClient.from_config(config)
try:
    client_wrapper.delete_tenant(
        collection_name=config.qdrant_collection_name,
        tenant_id=tenant
    )
    print(f"Cleared Qdrant for tenant {tenant}")
except Exception as e:
    print(f"Failed to clear Qdrant: {e}")

# Clear Neo4j
neo4j_client = Neo4jStorageClient.from_config(config)
try:
    neo4j_client.execute_write("MATCH (n {tenant_id: $tenant}) DETACH DELETE n", {"tenant": tenant})
    print(f"Cleared Neo4j for tenant {tenant}")
except Exception as e:
    print(f"Failed to clear Neo4j: {e}")
EOF
backend/.venv/bin/python backend/evaluation/clear_benchmark_data.py

echo "3. Running MCP ingestion pipeline on the massive text corpus (WARNING: High Token Cost)..."
cat << 'EOF' > backend/evaluation/run_ingestion.py
from backend.ingestion.__main__ import run_ingestion
from backend.config import get_config

file_path = "backend/tests/data/graphrag_test_corpus.txt"
print(f"Starting ingestion for {file_path}")
with open(file_path, "r", encoding="utf-8") as f:
    text = f.read()

config = get_config()
mock_schema = {
    "entities": ["Concept", "Observation", "Disease", "Symptom"],
    "relations": {"Concept": {"Disease": ["CAUSES", "TREATS", "RELATES_TO"]}}
}

run_ingestion(
    config=config,
    text=text,
    schema=mock_schema,
    tenant_id="benchmark",
    fast_extraction=False,
    chunk_size=1000,
    chunk_overlap=200
)
print("Ingestion complete.")
EOF
backend/.venv/bin/python backend/evaluation/run_ingestion.py

echo "4. Running full benchmark evaluation..."
backend/.venv/bin/python -u backend/evaluation/benchmark_rag.py | tee backend/evaluation/full_benchmark_run.log

echo "Done! Final results saved to backend/evaluation/results.json and backend/evaluation/full_benchmark_run.log"
