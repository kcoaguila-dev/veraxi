import pytest
import uuid
from backend.mcp_server.tools.delete_entity import delete_entity
from backend.mcp_server.tools.delete_relationship import delete_relationship
from backend.mcp_server.tools.delete_vector import delete_vector
from backend.mcp_server.tools.get_schema import get_graph_schema
from backend.mcp_server.tools.run_analytics import run_community_detection
from backend.mcp_server.tools.update_document import update_document_metadata
from backend.mcp_server.tools.update_entity import update_entity
from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient
from qdrant_client.http.models import PointStruct

@pytest.fixture
def test_tenant():
    return "test_tenant"

@pytest.fixture
def neo4j_client(patch_env):
    config = get_config()
    print(f"DEBUG IN FIXTURE: config.neo4j_uri={config.neo4j_uri}")
    client = Neo4jStorageClient.from_config(config)
    yield client
    client.close()

@pytest.fixture
def qdrant_client(patch_env):
    config = get_config()
    return QdrantStorageClient.from_config(config)


def test_delete_entity(neo4j_client, test_tenant):
    # Setup
    neo4j_client.execute_read(
        "CREATE (n:Person {name: 'Test Delete Entity', tenant_id: $tenant_id})",
        {"tenant_id": test_tenant}
    )
    
    # Test
    result = delete_entity("Test Delete Entity", tenant_id=test_tenant)
    assert "Successfully deleted 1 entity" in result
    
    # Verify
    records = neo4j_client.execute_read(
        "MATCH (n:Person {name: 'Test Delete Entity', tenant_id: $tenant_id}) RETURN n",
        {"tenant_id": test_tenant}
    )
    assert len(records) == 0


def test_delete_relationship(neo4j_client, test_tenant):
    # Setup
    neo4j_client.execute_read(
        """
        CREATE (a:Person {name: 'NodeA', tenant_id: $tenant_id})
        CREATE (b:Person {name: 'NodeB', tenant_id: $tenant_id})
        CREATE (a)-[:KNOWS]->(b)
        """,
        {"tenant_id": test_tenant}
    )
    
    # Test
    result = delete_relationship("NodeA", "NodeB", "KNOWS", tenant_id=test_tenant)
    assert "Successfully deleted 1" in result
    assert "relationship(s)" in result
    
    # Verify relationship is gone but nodes remain
    nodes = neo4j_client.execute_read(
        "MATCH (n:Person {tenant_id: $tenant_id}) RETURN n.name as name",
        {"tenant_id": test_tenant}
    )
    names = [r["name"] for r in nodes]
    assert "NodeA" in names
    assert "NodeB" in names
    
    rels = neo4j_client.execute_read(
        "MATCH (a)-[r:KNOWS]->(b) WHERE a.tenant_id = $tenant_id RETURN r",
        {"tenant_id": test_tenant}
    )
    assert len(rels) == 0


def test_delete_vector(qdrant_client, patch_env, test_tenant):
    # Setup
    config = get_config()
    qdrant_client.create_collection(config.qdrant_collection_name)
    doc_id = str(uuid.uuid4())
    qdrant_client.client.upsert(
        collection_name=config.qdrant_collection_name,
        points=[
            PointStruct(
                id=doc_id,
                vector={"": [0.1] * 384, "text-sparse": {"indices": [], "values": []}},
                payload={"tenant_id": test_tenant, "text": "to be deleted"}
            )
        ]
    )
    
    # Test
    result = delete_vector(doc_id)
    assert "Successfully" in result
    
    # Verify
    records, _ = qdrant_client.client.scroll(
        collection_name=config.qdrant_collection_name,
        scroll_filter=None,
        limit=10
    )
    # Check if doc_id is among remaining records
    assert not any(record.id == doc_id for record in records)


def test_get_schema(neo4j_client, test_tenant):
    # Setup
    neo4j_client.execute_read(
        "CREATE (n:TestLabel {name: 'SchemaNode', tenant_id: $tenant_id})-[:TEST_REL]->(m:OtherLabel {tenant_id: $tenant_id})",
        {"tenant_id": test_tenant}
    )
    
    # Test
    schema_info = get_graph_schema()
    
    assert "TestLabel" in schema_info["node_labels"]
    assert "OtherLabel" in schema_info["node_labels"]
    assert "TEST_REL" in schema_info["relationship_types"]


from unittest.mock import patch

def test_run_analytics(neo4j_client, test_tenant):
    # Test the wrapper by mocking the actual implementation
    with patch("backend.mcp_server.tools.run_analytics.get_community_detection") as mock_gcd:
        mock_gcd.return_value = [{"community": 1, "size": 5}]
        result = run_community_detection(min_size=2)
        assert len(result) == 1
        assert result[0]["community"] == 1


def test_update_document_metadata(qdrant_client, patch_env, test_tenant):
    # Setup
    config = get_config()
    qdrant_client.create_collection(config.qdrant_collection_name)
    doc_id = str(uuid.uuid4())
    qdrant_client.client.upsert(
        collection_name=config.qdrant_collection_name,
        points=[
            PointStruct(
                id=doc_id,
                vector={"": [0.1] * 384, "text-sparse": {"indices": [], "values": []}},
                payload={"tenant_id": test_tenant, "original": True}
            )
        ]
    )
    
    # Test
    result = update_document_metadata(doc_id, {"new_key": "new_value", "original": False}, tenant_id=test_tenant)
    assert "Successfully updated metadata" in result
    
    # Verify
    records = qdrant_client.client.retrieve(
        collection_name=config.qdrant_collection_name,
        ids=[doc_id]
    )
    assert len(records) == 1
    assert records[0].payload["new_key"] == "new_value"
    assert records[0].payload["original"] is False
    assert records[0].payload["tenant_id"] == test_tenant


def test_update_entity(neo4j_client, test_tenant):
    # Setup
    neo4j_client.execute_read(
        "CREATE (n:Person {name: 'Update Me', tenant_id: $tenant_id, age: 30})",
        {"tenant_id": test_tenant}
    )
    
    # Test
    result = update_entity("Update Me", {"age": 31, "city": "New York"}, tenant_id=test_tenant)
    assert "Successfully updated properties for 1 entity(s)" in result
    
    # Verify
    records = neo4j_client.execute_read(
        "MATCH (n:Person {name: 'Update Me', tenant_id: $tenant_id}) RETURN n",
        {"tenant_id": test_tenant}
    )
    assert len(records) == 1
    node = records[0]["n"]
    assert node["age"] == 31
    assert node["city"] == "New York"
