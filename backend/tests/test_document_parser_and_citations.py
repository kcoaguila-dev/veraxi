from unittest.mock import MagicMock, patch

import pytest

from backend.ingestion.document_parser import (
    convert_document_to_markdown,
    extract_attachment_text,
    strip_and_resolve_page_number,
)
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient


def test_strip_and_resolve_page_number():
    raw = "<!-- page:1 -->\nThis is introductory text on the first page."
    cleaned, page = strip_and_resolve_page_number(raw)
    assert page == 1
    assert "<!-- page:1 -->" not in cleaned
    assert "This is introductory text" in cleaned

    # Subsequent chunk with no marker inherits last known page
    raw_next = "Continuing paragraph on the same page."
    cleaned_next, page_next = strip_and_resolve_page_number(raw_next, page)
    assert page_next == 1
    assert cleaned_next == raw_next

    # Page turn
    raw_p2 = "<!-- page:2 -->\nChapter two starts here."
    cleaned_p2, page_p2 = strip_and_resolve_page_number(raw_p2, page_next)
    assert page_p2 == 2
    assert "Chapter two starts here." in cleaned_p2


def test_document_parser_plain_text(tmp_path):
    txt_file = tmp_path / "sample.txt"
    txt_file.write_text("Hello from plain text file.", encoding="utf-8")

    out = convert_document_to_markdown(str(txt_file))
    assert "Hello from plain text file." in out

    attachment_out = extract_attachment_text(
        str(txt_file),
        "sample.txt",
        b"Hello from plain text file.",
        "text/plain",
    )
    assert "Hello from plain text file." in attachment_out


def test_qdrant_embedded_memory_mode():
    qdrant = QdrantStorageClient(url=":memory:")
    collection_name = "test_memory_col"

    qdrant.create_collection(collection_name, vector_size=4)
    point_ids = qdrant.insert_points(
        collection_name=collection_name,
        vectors=[[0.1, 0.2, 0.3, 0.4]],
        sparse_vectors=[{"indices": [1], "values": [0.5]}],
        payloads=[
            {
                "text": "test embedded text",
                "source": "manual.pdf",
                "page_number": 3,
                "chunk_index": 0,
            }
        ],
        tenant_id="embedded_tenant",
    )
    assert len(point_ids) == 1
    points = qdrant.get_points(collection_name, point_ids)
    assert len(points) == 1
    assert points[0]["payload"]["source"] == "manual.pdf"
    assert points[0]["payload"]["page_number"] == 3
    assert points[0]["payload"]["chunk_index"] == 0


def test_neo4j_upsert_relationship_sets_temporal_metadata():
    client = Neo4jStorageClient.__new__(Neo4jStorageClient)
    client.driver = MagicMock()
    mock_session = MagicMock()
    client.driver.session.return_value.__enter__.return_value = mock_session

    client.upsert_relationship(
        from_id="node_a",
        to_id="node_b",
        rel_type="WORKS_AT",
        properties={"source": "report.pdf"},
    )

    assert mock_session.run.called
    call_args = mock_session.run.call_args
    query = call_args[0][0]
    kwargs = call_args[1]

    assert "ON CREATE SET r.first_seen_at = $first_seen" in query
    assert "r.first_seen_at = coalesce(r.first_seen_at, $first_seen)" in query
    assert kwargs["from_id"] == "node_a"
    assert kwargs["to_id"] == "node_b"
    assert kwargs["props"]["source"] == "report.pdf"
    assert kwargs["props"]["active"] is True
    assert "last_confirmed_at" in kwargs["props"]
    assert "first_seen" in kwargs


@pytest.mark.asyncio
async def test_in_memory_redis_pool():
    from backend.storage.memory_redis import InMemoryRedisPool

    pool = InMemoryRedisPool()
    await pool.set("k1", "v1")
    assert await pool.get("k1") == b"v1"

    await pool.setex("k2", 3600, "v2")
    assert await pool.get("k2") == b"v2"

    await pool.hset("h1", "f1", "val1")
    assert await pool.hget("h1", "f1") == b"val1"
    assert await pool.hexists("h1", "f1") is True
    assert await pool.hgetall("h1") == {b"f1": b"val1"}
    await pool.hdel("h1", "f1")
    assert await pool.hexists("h1", "f1") is False

    await pool.sadd("s1", "m1", "m2")
    assert await pool.sismember("s1", "m1") is True
    assert await pool.sismember("s1", "m3") is False
    assert await pool.smembers("s1") == {b"m1", b"m2"}
    await pool.srem("s1", "m1")
    assert await pool.sismember("s1", "m1") is False

    await pool.delete("k1", "k2", "h1", "s1")
    assert await pool.get("k1") is None


def test_multilingual_spacy_loader_fallback():
    from backend.ingestion.extract import _load_spacy_model

    # Japanese request should load or fallback to multilingual model with sentencizer
    nlp = _load_spacy_model("ja")
    assert nlp is not None
    doc = nlp("これはテストです。次の文です。")
    sents = list(doc.sents)
    assert len(sents) >= 2


def test_sha256_deduplication_in_run_ingestion():
    from backend.ingestion.__main__ import run_ingestion

    mock_config = MagicMock()
    mock_config.qdrant_collection_name = "test_col"

    mock_qdrant = MagicMock()
    mock_qdrant.has_file_hash.return_value = True

    mock_neo4j = MagicMock()

    with (
        patch(
            "backend.ingestion.__main__.QdrantStorageClient.from_config",
            return_value=mock_qdrant,
        ),
        patch(
            "backend.ingestion.__main__.Neo4jStorageClient.from_config",
            return_value=mock_neo4j,
        ),
        patch("backend.ingestion.__main__.chunk_and_embed") as mock_chunk,
    ):
        result = run_ingestion(
            mock_config,
            text="Existing identical document content",
            schema={"entities": [], "relations": {}},
            tenant_id="test_tenant",
        )
        assert result["deduplicated"] is True
        assert result["nodes_inserted"] == 0
        assert result["vectors_inserted"] == 0
        assert "file_hash" in result
        mock_chunk.assert_not_called()
