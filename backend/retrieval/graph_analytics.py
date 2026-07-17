from typing import List, Dict, Any
from backend.storage.neo4j_client import Neo4jStorageClient


def get_community_detection(
    neo4j_client: Neo4jStorageClient, min_community_size: int = 1, tenant_id: str = "default"
) -> List[Dict[str, Any]]:
    """
    Uses Neo4j to find loosely connected components/communities within a specific tenant's graph.
    This simulates community detection by grouping connected nodes.
    We return the communities and the nodes in each.
    """
    query_grouping = """
    MATCH (n {tenant_id: $tenant_id})
    WITH labels(n)[0] AS community, count(n) AS size, collect(n.name) AS members
    WHERE size >= $min_community_size
    RETURN community, size, members
    ORDER BY size DESC
    """

    return neo4j_client.execute_read(
        query_grouping, parameters={"min_community_size": min_community_size, "tenant_id": tenant_id}
    )


def get_node_degree_centrality(
    neo4j_client: Neo4jStorageClient, limit: int = 10, tenant_id: str = "default"
) -> List[Dict[str, Any]]:
    """
    Returns the nodes with the most relationships for a given tenant.
    """
    query = """
    MATCH (n {tenant_id: $tenant_id})-[r]-()
    WITH n, count(r) AS degree
    RETURN n.name AS name, labels(n)[0] AS label, degree
    ORDER BY degree DESC
    LIMIT toInteger($limit)
    """

    return neo4j_client.execute_read(query, parameters={"limit": limit, "tenant_id": tenant_id})
