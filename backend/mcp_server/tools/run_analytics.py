from typing import Dict, Any, List
from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.retrieval.graph_analytics import get_community_detection

def run_community_detection(min_size: int = 2, tenant_id: str = "default") -> List[Dict[str, Any]]:
    """
    Runs basic community detection algorithms on the knowledge graph
    to find clusters of interconnected information.
    """
    config = get_config()
    neo4j = Neo4jStorageClient(
        uri=config.neo4j_uri, user=config.neo4j_user, password=config.neo4j_password
    )
    
    try:
        return get_community_detection(neo4j, min_community_size=min_size, tenant_id=tenant_id)
    finally:
        neo4j.close()
