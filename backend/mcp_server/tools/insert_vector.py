import logging
from typing import Any

import sentry_sdk

from backend.config import get_config
from backend.ingestion.chunk_embed import embed_text, embed_text_sparse
from backend.storage.qdrant_client import QdrantStorageClient

logger = logging.getLogger(__name__)


def _sync_vectors_to_neo4j(
    config, qdrant_client, collection_name: str, point_ids: list[str], tenant_id: str
) -> None:
    """Enforces dual-engine invariant: links newly inserted Qdrant points with Neo4j :Chunk nodes."""
    try:
        from backend.storage.neo4j_client import Neo4jStorageClient

        neo4j_client = Neo4jStorageClient.from_config(config)
        updates_by_point_id: dict[str, dict] = {}
        try:
            for pid in point_ids:
                node_id = neo4j_client.upsert_entity(
                    label="Chunk",
                    tenant_id=tenant_id,
                    name=f"Chunk_{pid[:8]}",
                    aliases=[],
                    properties={"source": "mcp_insert_vectors"},
                    qdrant_point_ids=[pid],
                )
                updates_by_point_id[pid] = {"neo4j_node_ids": [node_id]}
        finally:
            neo4j_client.close()

        qdrant_client.batch_set_payloads(
            collection_name=collection_name,
            payload_by_point_id=updates_by_point_id,
        )
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.error(
            f"Failed to synchronize vectors to Neo4j nodes; rolling back inserted Qdrant points: {exc}"
        )
        try:
            qdrant_client.delete_points(
                collection_name=collection_name, point_ids=point_ids
            )
        except Exception as rb_exc:
            sentry_sdk.capture_exception(rb_exc)
            logger.error(f"Compensating rollback failed: {rb_exc}")
        raise


def insert_vectors(texts: list[str], tenant_id: str = "default") -> dict[str, Any]:
    """
    Generate embeddings for raw texts using local models and insert into Qdrant.
    Does not require a Gemini API key.
    """
    config = get_config()
    qdrant_client = QdrantStorageClient.from_config(config)
    COLLECTION_NAME = config.qdrant_collection_name
    qdrant_client.create_collection(COLLECTION_NAME)

    vectors = []
    sparse_vectors = []
    payloads = []

    for text in texts:
        vector = embed_text(text)
        sparse_vec = embed_text_sparse(text)
        vectors.append(vector)
        sparse_vectors.append(sparse_vec)
        payloads.append({"text": text, "tenant_id": tenant_id})

    if vectors:
        point_ids = qdrant_client.insert_points(
            collection_name=COLLECTION_NAME,
            vectors=vectors,
            sparse_vectors=sparse_vectors,
            payloads=payloads,
            tenant_id=tenant_id,
        )

        # Invariant: Every Qdrant point must have a corresponding Neo4j node and vice versa
        _sync_vectors_to_neo4j(
            config, qdrant_client, COLLECTION_NAME, point_ids, tenant_id
        )

        return {
            "status": "success",
            "vectors_inserted": len(point_ids),
            "point_ids": point_ids,
        }

    return {"status": "success", "vectors_inserted": 0, "point_ids": []}
