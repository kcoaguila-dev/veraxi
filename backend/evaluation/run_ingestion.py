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
