"""Unit tests for high-speed book extraction and batched embedding."""

from backend.ingestion.chunk_embed import chunk_and_embed, chunk_text
from backend.ingestion.extract import extract_entities_and_relations_fast
from backend.scripts.batch_ingest import extract_text


def test_chunk_text_basic():
    text = "Word " * 200
    chunks = chunk_text(text, chunk_size=100, overlap=20)
    assert len(chunks) > 1
    assert all(len(c) <= 100 for c in chunks)


def test_batched_chunk_and_embed():
    sample_text = (
        "Short selling and financial accounting forensics involve analyzing balance sheets, "
        "cash flow statements, and executive incentives. Thornton O'Glove and David Einhorn "
        "identified critical accounting shenanigans."
    )
    results = chunk_and_embed(sample_text, chunk_size=100, chunk_overlap=20, batch_size=4)
    assert len(results) > 0
    for chunk, dense_vec, sparse_vec in results:
        assert isinstance(chunk, str)
        assert len(dense_vec) == 384
        assert "indices" in sparse_vec
        assert "values" in sparse_vec
        assert len(sparse_vec["indices"]) == len(sparse_vec["values"])


def test_fast_entity_extraction_with_large_text():
    # Verify that texts with repetition do not crash spaCy's max_length
    schema = {
        "entities": ["Person", "Organization", "Concept"],
        "relations": {
            "Person": {"Organization": ["WORKS_FOR", "FOUNDED"]},
        },
    }
    repeated_text = (
        "Howard Schilit analyzed Sunbeam and Enron for accounting irregularities. "
        "David Einhorn investigated Allied Capital. "
    ) * 50

    entities, relations = extract_entities_and_relations_fast(
        repeated_text, schema, language="en"
    )
    assert len(entities) > 0
    entity_names = {e["name"] for e in entities}
    assert any("Einhorn" in name or "Schilit" in name for name in entity_names)


def test_extract_text_empty_or_nonexistent():
    res = extract_text("/tmp/non_existent_file_path.pdf", fast=True)
    assert res == ""


def test_resolve_entities_scalability():
    from backend.ingestion.entity_resolution import resolve_entities
    import time

    # Simulate 500 entities with realistic duplicates found in books
    entities = []
    base_names = [
        "David Einhorn", "David M. Einhorn", "Allied Capital", "Allied Capital Corp",
        "Howard Schilit", "Thornton O'Glove", "SEC", "Securities and Exchange Commission",
        "Sunbeam", "Enron", "Arthur Andersen", "Tyco International"
    ]
    for i in range(500):
        name = base_names[i % len(base_names)]
        entities.append({
            "type": "Organization" if "Capital" in name or "SEC" in name or "Commission" in name or "Sunbeam" in name or "Enron" in name or "Andersen" in name or "Tyco" in name else "Person",
            "name": name,
            "properties": {"mention_index": i}
        })

    start_time = time.time()
    resolved, alias_mapping = resolve_entities(entities)
    duration = time.time() - start_time

    # Must resolve 500 entities in under 10 seconds (previously took >10 minutes)
    assert duration < 10.0
    assert len(resolved) <= len(base_names)
    assert len(alias_mapping) >= len(base_names)

