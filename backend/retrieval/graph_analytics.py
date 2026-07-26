from typing import List, Dict, Any
from backend.storage.neo4j_client import Neo4jStorageClient


def get_community_detection(
    neo4j_client: Neo4jStorageClient, min_community_size: int = 1, tenant_id: str = "default"
) -> List[Dict[str, Any]]:
    """
    Uses the Neo4j Graph Data Science (GDS) Louvain algorithm to find densely connected components.
    Uses an anonymous Cypher projection to strictly isolate the graph to the given tenant_id.
    """
    query_grouping = """
    CALL gds.louvain.stream({
        nodeQuery: 'MATCH (n {tenant_id: $tenant_id}) RETURN id(n) AS id',
        relationshipQuery: 'MATCH (n {tenant_id: $tenant_id})-[r]->(m {tenant_id: $tenant_id}) RETURN id(n) AS source, id(m) AS target',
        parameters: { tenant_id: $tenant_id }
    })
    YIELD nodeId, communityId
    WITH gds.util.asNode(nodeId) AS n, communityId
    WITH communityId AS community, count(n) AS size, collect(n.name) AS members
    WHERE size >= $min_community_size
    RETURN toString(community) AS community, size, members
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
