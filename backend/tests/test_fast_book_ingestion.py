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
    results = chunk_and_embed(
        sample_text, chunk_size=100, chunk_overlap=20, batch_size=4
    )
    assert len(results) > 0
    from backend.config import get_config

    expected_dim = get_config().embedding_dimension
    for chunk, dense_vec, sparse_vec in results:
        assert isinstance(chunk, str)
        assert len(dense_vec) == expected_dim
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

    entities, _relations = extract_entities_and_relations_fast(
        repeated_text, schema, language="en"
    )
    assert len(entities) > 0
    entity_names = {e["name"] for e in entities}
    assert any("Einhorn" in name or "Schilit" in name for name in entity_names)


def test_fast_extraction_never_hallucinates_schema_relation_on_cooccurrence():
    """Verify that co-occurring entities without grounding emit MENTIONED_WITH instead of guessing allowed_t1_t2[0]."""
    schema = {
        "entities": ["Person", "Organization"],
        "relations": {
            "Person": {"Organization": ["WORKS_AT"]},
            "Organization": {"Organization": ["ACQUIRED"]},
        },
    }
    # 1. "Powell criticized FTX": verb is "criticized", not "works", so WORKS_AT must NOT be emitted.
    # 2. "Alice works at FTX": verb is "works", matching WORKS_AT.
    # 3. "Bob did not work at FTX": verb is negated by "not", so WORKS_AT must NOT be emitted.
    # 4. "Figma was acquired by Adobe": passive voice must emit Adobe -> Figma, not Figma -> Adobe.
    text = (
        "Jerome Powell criticized FTX during the hearing. "
        "Alice works at FTX. "
        "Bob did not work at FTX. "
        "Figma was acquired by Adobe."
    )
    entities, relations = extract_entities_and_relations_fast(
        text, schema, language="en"
    )
    assert len(entities) >= 3

    # Check relation tuples: (from, to, type)
    rel_tuples = {(r["from_entity"], r["to_entity"], r["type"]) for r in relations}

    # Powell & FTX: must NOT be WORKS_AT
    assert ("Jerome Powell", "FTX", "WORKS_AT") not in rel_tuples
    assert ("Jerome Powell", "FTX", "MENTIONED_WITH") in rel_tuples

    # Alice & FTX: MUST be WORKS_AT (grounded in verb "works")
    assert ("Alice", "FTX", "WORKS_AT") in rel_tuples

    # Bob & FTX: must NOT be WORKS_AT (negated by "did not")
    assert ("Bob", "FTX", "WORKS_AT") not in rel_tuples
    assert ("Bob", "FTX", "MENTIONED_WITH") in rel_tuples

    # Passive voice: Adobe ACQUIRED Figma (not Figma ACQUIRED Adobe)
    assert ("Adobe", "Figma", "ACQUIRED") in rel_tuples
    assert ("Figma", "Adobe", "ACQUIRED") not in rel_tuples


def test_extract_text_empty_or_nonexistent():
    res = extract_text("/tmp/non_existent_file_path.pdf", fast=True)
    assert res == ""


def test_resolve_entities_scalability():
    import time

    from backend.ingestion.entity_resolution import resolve_entities

    # Simulate 500 entities with realistic duplicates found in books
    entities = []
    base_names = [
        "David Einhorn",
        "David M. Einhorn",
        "Allied Capital",
        "Allied Capital Corp",
        "Howard Schilit",
        "Thornton O'Glove",
        "SEC",
        "Securities and Exchange Commission",
        "Sunbeam",
        "Enron",
        "Arthur Andersen",
        "Tyco International",
    ]
    for i in range(500):
        name = base_names[i % len(base_names)]
        entities.append(
            {
                "type": "Organization"
                if "Capital" in name
                or "SEC" in name
                or "Commission" in name
                or "Sunbeam" in name
                or "Enron" in name
                or "Andersen" in name
                or "Tyco" in name
                else "Person",
                "name": name,
                "properties": {"mention_index": i},
            }
        )

    start_time = time.time()
    resolved, alias_mapping = resolve_entities(entities)
    duration = time.time() - start_time

    # Must resolve 500 entities in under 10 seconds (previously took >10 minutes)
    assert duration < 10.0
    assert len(resolved) <= len(base_names)
    assert len(alias_mapping) >= len(base_names)


def test_chunk_text_prefers_sentence_boundaries():
    text = "Sentence one is clear. Sentence two is very informative. Sentence three finishes."
    chunks = chunk_text(text, chunk_size=55, overlap=10)
    assert len(chunks) >= 2
    assert all(len(c) <= 55 for c in chunks)
    assert chunks[0].endswith(".")


def test_write_to_graph_word_boundary_linking_prevents_substring_false_positives():
    from unittest.mock import MagicMock
    from backend.ingestion.graph_write import IngestionPayload, write_to_graph

    mock_neo4j = MagicMock()
    mock_neo4j.upsert_entity.return_value = "node_ai"

    payload = IngestionPayload(
        entities=[{"name": "AI", "type": "Concept", "aliases": ["AI"]}],
        relations=[],
        qdrant_point_ids={
            "Please wait here for confirmation.": "p1",
            "Modern AI systems are advancing rapidly.": "p2",
        },
    )

    _, q2n, q2names = write_to_graph(mock_neo4j, payload, tenant_id="t1")
    # 'AI' must ONLY link to p2, not p1 ('wait' must not match 'AI')
    assert "p2" in q2n
    assert q2names.get("p2") == ["AI"]
    assert "p1" not in q2names
