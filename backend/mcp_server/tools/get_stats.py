import sentry_sdk
from typing import Dict, Any
from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient

def get_database_stats(tenant_id: str = "default") -> Dict[str, Any]:
    """
    Returns high-level statistics about the current tenant's database size.
    """
    config = get_config()
    
    stats = {}
    
    # 1. Neo4j Stats
    neo4j = Neo4jStorageClient.from_config(config)
    try:
        node_query = "MATCH (n {tenant_id: $tenant_id}) RETURN count(n) AS node_count"
        rel_query = "MATCH ()-[r {tenant_id: $tenant_id}]->() RETURN count(r) AS rel_count"
        
        node_res = neo4j.execute_read(node_query, {"tenant_id": tenant_id})
        rel_res = neo4j.execute_read(rel_query, {"tenant_id": tenant_id})
        
        stats["neo4j_nodes"] = node_res[0]["node_count"] if node_res else 0
        stats["neo4j_relationships"] = rel_res[0]["rel_count"] if rel_res else 0
    except Exception as e:
        sentry_sdk.capture_exception(e)
        stats["neo4j_error"] = str(e)
    finally:
        neo4j.close()

    # 2. Qdrant Stats
    try:
        qdrant = QdrantStorageClient.from_config(config)
        COLLECTION_NAME = config.qdrant_collection_name
        stats["qdrant_vectors"] = qdrant.count(COLLECTION_NAME, tenant_id=tenant_id)
    except Exception as e:
        sentry_sdk.capture_exception(e)
        stats["qdrant_error"] = str(e)
        
    return stats
