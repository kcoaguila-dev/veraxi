import pytest

from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient


@pytest.fixture
def neo4j_client(patch_env):
    config = get_config()
    client = Neo4jStorageClient.from_config(config)
    yield client
    client.close()


@pytest.fixture
def qdrant_client(patch_env):
    config = get_config()
    return QdrantStorageClient.from_config(config)


def test_neo4j_create_node_and_relationship(neo4j_client):
    tenant_id = "test_tenant"

    # Create two nodes
    node1_id = neo4j_client.create_node(
        "TestNode", {"name": "Node1", "tenant_id": tenant_id}
    )
    assert node1_id is not None
    assert isinstance(node1_id, str)

    node2_id = neo4j_client.create_node(
        "TestNode", {"name": "Node2", "tenant_id": tenant_id}
    )
    assert node2_id is not None

    # Create relationship
    neo4j_client.create_relationship(node1_id, node2_id, "TEST_REL")

    # Verify relationship exists
    records = neo4j_client.execute_read(
        "MATCH (a)-[r:TEST_REL]->(b) WHERE a.id = $id1 AND b.id = $id2 RETURN r",
        {"id1": node1_id, "id2": node2_id},
    )
    assert len(records) == 1


def test_qdrant_create_collection_and_insert(qdrant_client):
    collection_name = "test_collection"
    tenant_id = "test_tenant"

    # Create collection
    qdrant_client.create_collection(collection_name, vector_size=4)

    # Insert vectors
    dense_vectors = [[0.1, 0.2, 0.3, 0.4], [0.5, 0.6, 0.7, 0.8]]
    sparse_vectors = [
        {"indices": [1, 2], "values": [0.5, 0.5]},
        {"indices": [2, 3], "values": [0.8, 0.2]},
    ]
    payloads = [{"text": "hello"}, {"text": "world"}]

    point_ids = qdrant_client.insert_points(
        collection_name, dense_vectors, sparse_vectors, payloads, tenant_id=tenant_id
    )

    assert len(point_ids) == 2

    # Verify points
    points = qdrant_client.get_points(collection_name, point_ids)
    assert len(points) == 2
    for point in points:
        assert point["payload"]["tenant_id"] == tenant_id
        assert "text" in point["payload"]

    # Re-insert the exact same payload to verify 100% idempotency (deterministic chunk hashing)
    point_ids_again = qdrant_client.insert_points(
        collection_name, dense_vectors, sparse_vectors, payloads, tenant_id=tenant_id
    )
    assert point_ids_again == point_ids, (
        "Point IDs must be deterministic on duplicate ingestion"
    )

    # Test file_hash detection and document-level replacement
    hash_payloads = [
        {
            "text": "hash doc chunk 1",
            "file_hash": "sha256_abc123",
            "document_id": "doc_v1",
        },
        {
            "text": "hash doc chunk 2",
            "file_hash": "sha256_abc123",
            "document_id": "doc_v1",
        },
    ]
    hash_pids = qdrant_client.insert_points(
        collection_name,
        dense_vectors,
        sparse_vectors,
        hash_payloads,
        tenant_id=tenant_id,
    )
    assert len(hash_pids) == 2

    # Check has_file_hash works
    assert (
        qdrant_client.has_file_hash(
            collection_name, "sha256_abc123", tenant_id=tenant_id
        )
        is True
    )
    assert (
        qdrant_client.has_file_hash(
            collection_name, "nonexistent_hash", tenant_id=tenant_id
        )
        is False
    )

    # Check delete_by_document works
    deleted = qdrant_client.delete_by_document(
        collection_name, "doc_v1", tenant_id=tenant_id
    )
    assert deleted == 2
    assert (
        qdrant_client.has_file_hash(
            collection_name, "sha256_abc123", tenant_id=tenant_id
        )
        is False
    )

    # Attempt to change vector dimension on a non-empty collection without force_recreate
    # Must raise ValueError to prevent silent data destruction
    with pytest.raises(ValueError, match="Refusing to delete existing collection"):
        qdrant_client.create_collection(
            collection_name, vector_size=8, force_recreate=False
        )


def test_qdrant_search_hybrid_prefetch_overfetch(qdrant_client):
    from unittest.mock import MagicMock

    mock_internal_client = MagicMock()
    mock_resp = MagicMock()
    mock_resp.points = [
        MagicMock(id="p1", score=0.85, payload={"text": "chunk 1"}),
        MagicMock(id="p2", score=0.75, payload={"text": "chunk 2"}),
    ]
    mock_internal_client.query_points.return_value = mock_resp

    orig_client = qdrant_client.client
    try:
        qdrant_client.client = mock_internal_client
        hits = qdrant_client.search_hybrid(
            collection_name="test_col",
            query_vector=[0.1, 0.2, 0.3, 0.4],
            sparse_query_vector={"indices": [1], "values": [0.5]},
            limit=5,
            tenant_id="tenant_x",
        )

        assert len(hits) == 2
        mock_internal_client.query_points.assert_called_once()
        call_kwargs = mock_internal_client.query_points.call_args.kwargs
        # Verify prefetch limit was over-fetched (max(5*2, 20) == 20)
        prefetch = call_kwargs["prefetch"]
        assert len(prefetch) == 2
        assert prefetch[0].limit == 20
        assert prefetch[1].limit == 20
        # Verify quantization search params were passed inside the dense Prefetch leg
        assert prefetch[1].params is not None
        assert prefetch[1].params.quantization.rescore is True
        assert prefetch[1].params.quantization.oversampling == 2.0
        # Verify quantization search params were configured for rescoring
        search_params = call_kwargs.get("search_params")
        assert search_params is not None
        assert search_params.quantization.rescore is True
        assert search_params.quantization.oversampling == 2.0
    finally:
        qdrant_client.client = orig_client

