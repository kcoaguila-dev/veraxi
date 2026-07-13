import pytest
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.ingestion.__main__ import main as run_ingestion

def test_ingestion_linking(patch_env):
    config = get_config()

    # Initialize clients for setup/teardown
    qdrant = QdrantStorageClient(url=config.qdrant_url, api_key=config.qdrant_api_key)
    neo4j = Neo4jStorageClient(uri=config.neo4j_uri, user=config.neo4j_user, password=config.neo4j_password)

    COLLECTION_NAME = "veraxi_docs"

    # Clear Neo4j
    with neo4j.driver.session() as session:
        session.run("MATCH (n) DETACH DELETE n")

    # Clear Qdrant
    try:
        qdrant.client.delete_collection(COLLECTION_NAME)
    except Exception:
        pass

    # 0. Run the orchestrator
    run_ingestion()

    # 1. Fetch all nodes from Neo4j (test database is empty)
    query = "MATCH (n) RETURN n.id AS id, n.qdrant_point_id AS qdrant_point_id"

    with neo4j.driver.session() as session:
        result = session.run(query)
        nodes = [record.data() for record in result]

    # We must have at least some nodes to test
    assert len(nodes) > 0, "No nodes found in Neo4j. Did ingestion run?"

    # Collect all Qdrant IDs referenced by Neo4j nodes
    qdrant_ids_from_neo4j = set()
    for node in nodes:
        # Assert: every Neo4j node has qdrant_point_id property
        assert node.get("qdrant_point_id") is not None, f"Node {node['id']} is missing qdrant_point_id"
        qdrant_ids_from_neo4j.add(node["qdrant_point_id"])

    # 2. Verify all these Qdrant IDs exist in Qdrant
    points = qdrant.get_points(COLLECTION_NAME, list(qdrant_ids_from_neo4j))
    found_qdrant_ids = set([p["id"] for p in points])

    for q_id in qdrant_ids_from_neo4j:
        # Assert: every qdrant_point_id in Neo4j points to an existing Qdrant point
        assert q_id in found_qdrant_ids, f"Qdrant point {q_id} referenced by Neo4j does not exist in Qdrant"

    # 3. Assert: every Qdrant point can be found in Neo4j (via qdrant_point_id)
    scroll_result = qdrant.client.scroll(
        collection_name=COLLECTION_NAME,
        limit=100
    )
    all_qdrant_points = scroll_result[0]
    all_qdrant_ids = {p.id for p in all_qdrant_points}

    for q_id in all_qdrant_ids:
        assert q_id in qdrant_ids_from_neo4j, f"Qdrant point {q_id} is missing from Neo4j nodes"

    neo4j.close()