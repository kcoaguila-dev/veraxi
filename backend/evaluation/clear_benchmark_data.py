from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient

tenant = "benchmark"
config = get_config()

# Clear Qdrant
client_wrapper = QdrantStorageClient.from_config(config)
try:
    client_wrapper.delete_tenant(
        collection_name=config.qdrant_collection_name,
        tenant_id=tenant
    )
    print(f"Cleared Qdrant for tenant {tenant}")
except Exception as e:
    print(f"Failed to clear Qdrant: {e}")

# Clear Neo4j
neo4j_client = Neo4jStorageClient.from_config(config)
try:
    neo4j_client.execute_write("MATCH (n {tenant_id: $tenant}) DETACH DELETE n", {"tenant": tenant})
    print(f"Cleared Neo4j for tenant {tenant}")
except Exception as e:
    print(f"Failed to clear Neo4j: {e}")
