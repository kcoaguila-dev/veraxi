#!/bin/bash

# Master script to run the GraphRAG evaluation suite using deterministic scoring
# This suite is designed to fit inside standard API Free Tiers by using F1 Token Overlap

set -e

WORKSPACE_DIR="/home/ubuntu/src/ai/veraxi"
cd "$WORKSPACE_DIR"

echo "1. Generating 150-question stratified benchmark corpus..."
backend/.venv/bin/python backend/evaluation/generate_benchmark.py --dataset graphrag_bench --samples 150

echo "2. Clearing previous benchmark tenant data from Qdrant and Neo4j..."
backend/.venv/bin/python backend/evaluation/clear_benchmark_data.py

echo "3. Running MCP ingestion pipeline on the text corpus..."
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

echo "4. Running deterministic benchmark evaluation (F1 Token Overlap)..."
backend/.venv/bin/python -u backend/evaluation/benchmark_deterministic.py | tee backend/evaluation/deterministic_benchmark_run.log

echo "Done! Final results saved to backend/evaluation/results.json and backend/evaluation/deterministic_benchmark_run.log"
