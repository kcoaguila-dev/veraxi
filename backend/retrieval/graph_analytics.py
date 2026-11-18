from typing import Any

from backend.storage.neo4j_client import Neo4jStorageClient


def get_community_detection(
    neo4j_client: Neo4jStorageClient,
    min_community_size: int = 1,
    tenant_id: str = "default",
) -> list[dict[str, Any]]:
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

    try:
        return neo4j_client.execute_read(
            query_grouping,
            parameters={
                "min_community_size": min_community_size,
                "tenant_id": tenant_id,
            },
        )
    except Exception:
        return _fallback_communities(
            neo4j_client, min_community_size=min_community_size, tenant_id=tenant_id
        )


# ---------------------------------------------------------------------------
# Pure-Python fallback community detection (no GDS required)
#
# The previous fallback grouped nodes by Neo4j label, which reported
# the 3 node labels as "communities". This fallback instead runs a
# deterministic Louvain modularity optimization over the entity
# co-occurrence graph fetched with two parameterized reads. Chunk /
# UnlinkedChunk_* nodes and degree-0 nodes are excluded: chunks are
# provenance carriers, not community members.
# ---------------------------------------------------------------------------

_EXCLUDED_LABELS = {"Chunk"}
_EXCLUDED_PREFIXES = ("UnlinkedChunk_",)


def _is_community_member(name: Any, label: Any) -> bool:
    if not name or not isinstance(name, str):
        return False
    if label in _EXCLUDED_LABELS:
        return False
    return not name.startswith(_EXCLUDED_PREFIXES)


def _louvain(adjacency: dict[str, dict[str, float]]) -> dict[str, int]:
    """Deterministic Louvain: returns node -> community id.

    Nodes are visited in sorted order every pass, so the result is
    stable across runs for the same graph.
    """
    nodes = sorted(adjacency)
    if not nodes:
        return {}
    degree = {n: sum(adjacency[n].values()) for n in nodes}
    total = sum(degree.values()) / 2.0
    if total == 0:
        return {n: i for i, n in enumerate(nodes)}
    community = {n: i for i, n in enumerate(nodes)}
    members: dict[int, set[str]] = {i: {n} for i, n in enumerate(nodes)}
    sigma_tot = {i: degree[n] for i, n in enumerate(nodes)}

    improved = True
    passes = 0
    while improved and passes < 20:
        improved = False
        passes += 1
        for node in nodes:
            current = community[node]
            neighbour_weights: dict[int, float] = {}
            for neighbour, weight in adjacency[node].items():
                if neighbour == node:
                    continue
                target = community[neighbour]
                neighbour_weights[target] = neighbour_weights.get(target, 0.0) + weight
            # Remove node from its community before scoring moves.
            members[current].discard(node)
            sigma_tot[current] -= degree[node]
            best_community = current
            best_gain = 0.0
            for candidate in sorted(neighbour_weights):
                gain = neighbour_weights[candidate] - (
                    sigma_tot[candidate] * degree[node]
                ) / (2.0 * total)
                if gain > best_gain + 1e-12:
                    best_gain = gain
                    best_community = candidate
            community[node] = best_community
            members[best_community].add(node)
            sigma_tot[best_community] += degree[node]
            if best_community != current:
                improved = True
            if not members[current]:
                del members[current]
    # Renumber communities deterministically by smallest member name.
    ordered = sorted(members.items(), key=lambda kv: min(kv[1]))
    renumber = {old: new for new, (old, _) in enumerate(ordered)}
    return {node: renumber[community[node]] for node in nodes}


def detect_communities(
    nodes: list[dict[str, Any]],
    edges: list[tuple[str, str]],
    min_community_size: int = 1,
) -> list[dict[str, Any]]:
    """Pure community detection over entity nodes + co-occurrence edges.

    ``nodes`` are ``{"name", "label"}`` dicts; ``edges`` are
    ``(source_name, target_name)`` pairs. Returns briefing-shaped rows
    ``{"community", "size", "members"}`` sorted by size descending.
    """
    names = {
        node["name"]
        for node in nodes or []
        if _is_community_member(node.get("name"), node.get("label"))
    }
    adjacency: dict[str, dict[str, float]] = {name: {} for name in names}
    for source, target in edges or []:
        if source not in names or target not in names or source == target:
            continue
        adjacency[source][target] = adjacency[source].get(target, 0.0) + 1.0
        adjacency[target][source] = adjacency[target].get(source, 0.0) + 1.0
    # Degree-0 entities form no community.
    adjacency = {n: nbrs for n, nbrs in adjacency.items() if nbrs}
    if not adjacency:
        return []
    assignment = _louvain(adjacency)
    grouped: dict[int, list[str]] = {}
    for node, community_id in assignment.items():
        grouped.setdefault(community_id, []).append(node)
    rows: list[dict[str, Any]] = [
        {
            "community": str(community_id),
            "size": len(members),
            "members": sorted(members),
        }
        for community_id, members in grouped.items()
        if len(members) >= min_community_size
    ]
    rows.sort(key=lambda row: (-row["size"], row["members"][0]))
    return rows


def _fallback_communities(
    neo4j_client: Neo4jStorageClient,
    min_community_size: int = 1,
    tenant_id: str = "default",
) -> list[dict[str, Any]]:
    """Fetch the tenant's entity graph and cluster it in Python."""
    node_rows = neo4j_client.execute_read(
        """
        MATCH (n {tenant_id: $tenant_id})
        RETURN n.name AS name, coalesce(labels(n)[0], 'Entity') AS label
        """,
        parameters={"tenant_id": tenant_id},
    )
    edge_rows = neo4j_client.execute_read(
        """
        MATCH (a {tenant_id: $tenant_id})-[r]->(b {tenant_id: $tenant_id})
        RETURN a.name AS source, b.name AS target
        """,
        parameters={"tenant_id": tenant_id},
    )
    edges = [
        (row.get("source"), row.get("target"))
        for row in edge_rows or []
        if row.get("source") and row.get("target")
    ]
    return detect_communities(
        node_rows or [], edges, min_community_size=min_community_size
    )


def get_node_degree_centrality(
    neo4j_client: Neo4jStorageClient, limit: int = 10, tenant_id: str = "default"
) -> list[dict[str, Any]]:
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

    return neo4j_client.execute_read(
        query, parameters={"limit": limit, "tenant_id": tenant_id}
    )
