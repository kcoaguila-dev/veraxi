from backend.config import get_config
from backend.scripts.seed_dev_data import seed_database
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient


def test_seed_dev_data_pipeline(patch_env):
    """Verifies that seed_database creates valid linked entities in both stores."""
    tenant_id = "test_seed_tenant"
    summary = seed_database(tenant_id=tenant_id, clean=True)

    assert summary["tenant_id"] == tenant_id
    assert summary["qdrant_points"] == 3
    assert summary["neo4j_nodes"] >= 4
    assert summary["neo4j_relationships"] >= 4

    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)
    qdrant = QdrantStorageClient.from_config(config)

    try:
        # Verify Neo4j nodes have qdrant_point_ids linked
        records = neo4j.execute_read(
            "MATCH (n) WHERE n.tenant_id = $tenant_id RETURN n.name as name, n.qdrant_point_ids as qdrant_id",
            {"tenant_id": tenant_id},
        )
        assert len(records) >= 4
        for r in records:
            assert r["qdrant_id"] is not None
            assert len(r["qdrant_id"]) > 0

        # Verify Qdrant points have neo4j_node_ids
        from qdrant_client import models

        points = qdrant.client.scroll(
            collection_name=config.qdrant_collection_name,
            scroll_filter=models.Filter(
                must=[
                    models.FieldCondition(
                        key="tenant_id",
                        match=models.MatchValue(value=tenant_id),
                    )
                ]
            ),
            limit=10,
            with_payload=True,
        )[0]
        assert len(points) == 3
        for tp in points:
            assert "neo4j_node_ids" in tp.payload
            assert len(tp.payload["neo4j_node_ids"]) > 0

    finally:
        # Cleanup
        neo4j.execute_write(
            "MATCH (n) WHERE n.tenant_id = $tenant_id DETACH DELETE n",
            {"tenant_id": tenant_id},
        )
        neo4j.close()
