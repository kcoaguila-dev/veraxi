from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient
import pytest
from backend.ingestion.__main__ import main as run_ingestion


def _verify_neo4j_nodes_have_qdrant_ids(nodes: list[dict]) -> set[str]:
    qdrant_ids_from_neo4j = set()
    for node in nodes:
        assert node.get("qdrant_point_id") is not None, f"Node {node['id']} is missing qdrant_point_id"
        qdrant_ids_from_neo4j.add(node["qdrant_point_id"])
    return qdrant_ids_from_neo4j

def _verify_qdrant_points_exist(qdrant, collection_name: str, qdrant_ids_from_neo4j: set[str]):
    points = qdrant.get_points(collection_name, list(qdrant_ids_from_neo4j))
    found_qdrant_ids = {p["id"] for p in points}
    for q_id in qdrant_ids_from_neo4j:
        assert q_id in found_qdrant_ids, f"Qdrant point {q_id} referenced by Neo4j does not exist in Qdrant"

def _verify_all_qdrant_points_in_neo4j(qdrant, collection_name: str, qdrant_ids_from_neo4j: set[str]):
    all_qdrant_points = []
    next_page_offset = None
    while True:
        scroll_result = qdrant.client.scroll(
            collection_name=collection_name,
            limit=100,
            offset=next_page_offset
        )
        points, next_page_offset = scroll_result[0], scroll_result[1]
        all_qdrant_points.extend(points)
        if not next_page_offset:
            break

    all_qdrant_ids = {p.id for p in all_qdrant_points}
    for q_id in all_qdrant_ids:
        assert q_id in qdrant_ids_from_neo4j, f"Qdrant point {q_id} is missing from Neo4j nodes"

@pytest.mark.integration
def test_ingestion_linking(patch_env):
    config = get_config()

    # Initialize clients for setup/teardown
    qdrant = QdrantStorageClient.from_config(config)
    neo4j = Neo4jStorageClient.from_config(config)

    COLLECTION_NAME = config.qdrant_collection_name

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

    # Run verification helpers
    qdrant_ids_from_neo4j = _verify_neo4j_nodes_have_qdrant_ids(nodes)
    _verify_qdrant_points_exist(qdrant, COLLECTION_NAME, qdrant_ids_from_neo4j)
    _verify_all_qdrant_points_in_neo4j(qdrant, COLLECTION_NAME, qdrant_ids_from_neo4j)

    neo4j.close()
