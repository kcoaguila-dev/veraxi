import logging
import re
import sentry_sdk

from backend.config import get_config
from backend.retrieval.merge_rank import GraphHit
from backend.retrieval.provenance import build_graph_path
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.scope import scope_filter_values

logger = logging.getLogger(__name__)

MAX_ALLOWED_HOPS = 3


def _build_query_graph_params(
    entity_name: str,
    tenant_id: str,
    repo_key: str | None = None,
    repo_keys: list[str] | None = None,
    exclude_code_nodes: bool = False,
) -> dict:
    """Pre-processes entity query terms for whole-word / phrase-boundary Cypher matching."""
    trimmed = (entity_name or "").strip()
    norm_words = [w.lower() for w in re.findall(r"\w+", trimmed) if len(w) >= 2]
    # Padded normalized query text (spaces separating word tokens)
    padded_norm = f" {' '.join(norm_words)} " if norm_words else f" {trimmed.lower()} "
    # Padded raw lowercased query text (retaining hyphens/periods/original punctuation)
    padded_raw = f" {trimmed.lower()} "

    return {
        "entity_name": trimmed,
        "lower_name": trimmed.lower(),
        "query_tokens": norm_words,
        "padded_norm_query": padded_norm,
        "padded_raw_query": padded_raw,
        "tenant_id": tenant_id,
        "repo_key": repo_key,
        "repo_keys": list(repo_keys or []),
        "exclude_code_nodes": exclude_code_nodes,
    }


def _hydrate_graph_hits_from_qdrant(config, hits: list[GraphHit]) -> None:
    """Hydrate GraphHits with document chunk text, page_number, and source from Qdrant."""
    if not hits:
        return
    try:
        from backend.storage.qdrant_client import QdrantStorageClient

        qdrant = QdrantStorageClient.from_config(config)
        q_ids = [h.id for h in hits if not h.id.startswith("neo4j:")]
        if q_ids:
            q_points = qdrant.get_points(config.qdrant_collection_name, q_ids)
            q_map = {
                p["id"]: p.get("payload", {})
                for p in q_points
                if isinstance(p, dict) and "id" in p
            }
            for h in hits:
                if h.id in q_map:
                    for k, v in q_map[h.id].items():
                        if k in ("neo4j_node_ids", "qdrant_point_ids"):
                            continue
                        if k not in h.payload or not h.payload[k]:
                            h.payload[k] = v
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.warning(f"Failed to hydrate graph hits from Qdrant payloads: {exc}")


def query_graph(
    entity_name: str,
    max_hops: int = 2,
    tenant_id: str = "default",
    source_scope: dict | None = None,
) -> list[GraphHit]:
    """
    Perform a parameterized Cypher traversal from a starting entity out to max_hops.
    Returns results as GraphHit objects ready for merge_rank.
    No string-concatenated queries for user inputs.

    ``source_scope`` (Code Mode) may pin the traversal to one or
    more repos: the ``$repo_keys`` parameter then filters ONLY code
    nodes (CodeFile/CodeModule/Class/Function — the nodes that carry
    a ``repo_key`` property), on the start node, the end node, and
    every intermediate node of the path. Shared public-tenant nodes
    (CVE, CWE, Package, ATT&CK) and ordinary entities carry no
    repo_key and are never filtered out by it. A scope that names
    document sources but no repo sets ``$exclude_code_nodes`` so the
    traversal cannot silently widen to every repo's code nodes.
    """
    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)
    neo4j.ensure_entity_constraint("Entity")

    # max_hops is an integer and controlled/validated by us (or typed as int from MCP tool).
    # We must ensure it's a positive integer to avoid injection.
    max_hops = min(max(1, int(max_hops)), MAX_ALLOWED_HOPS)

    repo_keys, source_ids = scope_filter_values(source_scope)
    params = _build_query_graph_params(
        entity_name,
        tenant_id,
        repo_key=repo_keys[0] if len(repo_keys) == 1 else None,
        repo_keys=repo_keys,
        exclude_code_nodes=(
            isinstance(source_scope, dict)
            and not repo_keys
            and bool(source_ids)
        ),
    )

    # We parameterize all user inputs and rank candidate start nodes by match quality:
    # Tier 0: Exact match on name/id or alias
    # Tier 1: Token match or whole-phrase boundary containment (raw and punctuation-normalized)
    # Tier 2: Substring match on longer entity names
    # Includes Entity plus security/code nodes (CVE, CWE, Package, CodeModule, Class, Function, CodeFile).
    query = f"""
    MATCH (start)
    WHERE (
        (start:Entity AND start.tenant_id = $tenant_id)
        OR ((start:CodeModule OR start:Class OR start:Function OR start:CodeFile OR start:SecurityFinding OR start:ReconFinding OR start:TargetHost OR start:SecurityAlert OR start:IOC) AND start.tenant_id = $tenant_id)
        OR ((start:CVE OR start:CWE OR start:Package OR start:AttackTechnique OR start:AttackTactic OR start:AttackMitigation) AND start.tenant_id IN [$tenant_id, 'public'])
      )
      AND ($repo_keys = [] OR coalesce(start.repo_key, '') IN $repo_keys
           OR NOT (start:CodeFile OR start:CodeModule OR start:Class OR start:Function))
      AND (NOT $exclude_code_nodes
           OR NOT (start:CodeFile OR start:CodeModule OR start:Class OR start:Function))
      AND coalesce(start.name, start.id, start.qualified_name) IS NOT NULL
    WITH start, coalesce(start.name, start.id, start.qualified_name) AS start_label
    WHERE (
        start_label = $entity_name
        OR toLower(start_label) = $lower_name
        OR any(a IN coalesce(start.aliases, []) WHERE toLower(a) = $lower_name)
        OR (size(start_label) >= 3 AND toLower(start_label) IN $query_tokens)
        OR any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND toLower(a) IN $query_tokens)
        OR (size(start_label) >= 3 AND $padded_norm_query CONTAINS (' ' + replace(replace(replace(toLower(start_label), '-', ' '), '.', ' '), '_', ' ') + ' '))
        OR (size(start_label) >= 3 AND $padded_raw_query CONTAINS (' ' + toLower(start_label) + ' '))
        OR any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND $padded_norm_query CONTAINS (' ' + replace(replace(replace(toLower(a), '-', ' '), '.', ' '), '_', ' ') + ' '))
        OR any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND $padded_raw_query CONTAINS (' ' + toLower(a) + ' '))
        OR (size($lower_name) >= 4 AND toLower(start_label) CONTAINS $lower_name)
      )
    WITH start, start_label,
         CASE
           WHEN start_label = $entity_name OR toLower(start_label) = $lower_name THEN 0
           WHEN any(a IN coalesce(start.aliases, []) WHERE toLower(a) = $lower_name) THEN 0
           WHEN size(start_label) >= 3 AND $padded_norm_query CONTAINS (' ' + replace(replace(replace(toLower(start_label), '-', ' '), '.', ' '), '_', ' ') + ' ') THEN 1
           WHEN size(start_label) >= 3 AND $padded_raw_query CONTAINS (' ' + toLower(start_label) + ' ') THEN 1
           WHEN any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND $padded_norm_query CONTAINS (' ' + replace(replace(replace(toLower(a), '-', ' '), '.', ' '), '_', ' ') + ' ')) THEN 1
           WHEN any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND $padded_raw_query CONTAINS (' ' + toLower(a) + ' ')) THEN 1
           WHEN size(start_label) >= 3 AND toLower(start_label) IN $query_tokens THEN 1
           WHEN any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND toLower(a) IN $query_tokens) THEN 1
           ELSE 2
         END AS match_tier
    ORDER BY match_tier ASC, size(start_label) DESC
    LIMIT 5
    MATCH path = (start)-[rels*1..{max_hops}]-(end)
    WHERE (end.tenant_id = $tenant_id
       OR ((end:CVE OR end:CWE OR end:Package OR end:AttackTechnique OR end:AttackTactic OR end:AttackMitigation) AND end.tenant_id = 'public'))
      AND ($repo_keys = [] OR coalesce(end.repo_key, '') IN $repo_keys
           OR NOT (end:CodeFile OR end:CodeModule OR end:Class OR end:Function))
      AND (NOT $exclude_code_nodes
           OR NOT (end:CodeFile OR end:CodeModule OR end:Class OR end:Function))
      AND ($repo_keys = [] OR all(n IN nodes(path) WHERE
            NOT (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
            OR coalesce(n.repo_key, '') IN $repo_keys))
      AND (NOT $exclude_code_nodes OR all(n IN nodes(path) WHERE
            NOT (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)))
    WITH start, start_label, end, last(rels) AS last_rel, size(rels) AS hop_distance,
         size([r IN rels WHERE type(r) IN ['MENTIONED_WITH', 'ASSOCIATED_WITH', 'RELATED_TO']]) AS noisy_hops,
         [n IN nodes(path) | coalesce(n.name, n.id, n.qualified_name)] AS path_node_names,
         [r IN relationships(path) | type(r)] AS path_rel_types
    ORDER BY hop_distance ASC, noisy_hops ASC
    WITH DISTINCT start, start_label, end, head(collect(last_rel)) AS last_rel, min(hop_distance) AS min_hops, min(noisy_hops) AS min_noisy_hops,
         head(collect(path_node_names)) AS path_node_names, head(collect(path_rel_types)) AS path_rel_types
    ORDER BY min_hops ASC, min_noisy_hops ASC
    LIMIT 50
    UNWIND (CASE WHEN size(coalesce(end.qdrant_point_ids, [])) > 0 THEN end.qdrant_point_ids ELSE ['neo4j:' + toString(coalesce(end.id, end.vuln_key, end.qualified_name, end.name))] END) AS qid
    RETURN DISTINCT coalesce(end.id, end.vuln_key, end.qualified_name, end.name) AS id,
           start_label AS source_entity,
           qid AS qdrant_point_id,
           labels(end) AS labels,
           properties(end) AS props,
           type(last_rel) AS relation_type,
           last_rel.last_confirmed_at AS last_confirmed_at,
           last_rel.source AS relation_source,
           path_node_names,
           path_rel_types,
           min_hops
    ORDER BY min_hops ASC
    LIMIT 100
    """

    # Execute query
    results = neo4j.execute_read(query, params)
    neo4j.close()

    # Return as GraphHit objects
    hits = []
    # Deduplicate node IDs explicitly just in case
    seen = set()
    for row in results:
        q_id = row.get("qdrant_point_id")
        if not q_id:
            if row.get("id"):
                q_id = f"neo4j:{row['id']}"
            else:
                continue

        if q_id not in seen:
            seen.add(q_id)
            payload = (
                row.get("props", {}).copy()
                if isinstance(row.get("props"), dict)
                else {}
            )
            payload.pop("qdrant_point_ids", None)
            payload["labels"] = row.get("labels", [])
            src = row.get("source_entity")
            if src:
                payload["source_entity"] = src
            rel = row.get("relation_type")
            if rel:
                payload["relation_type"] = rel
            if row.get("last_confirmed_at"):
                payload["last_confirmed_at"] = row.get("last_confirmed_at")
            if row.get("relation_source"):
                payload["relation_source"] = row.get("relation_source")
            # Provenance: store the captured traversal path only when the
            # Cypher capture is complete; never reconstruct a partial one.
            graph_path = build_graph_path(
                row.get("path_node_names") or [],
                row.get("path_rel_types") or [],
            )
            if graph_path is not None:
                payload["graph_path"] = graph_path
            hits.append(GraphHit(id=q_id, payload=payload))

    # Hydrate GraphHits with document chunk text, page_number, and source from Qdrant
    _hydrate_graph_hits_from_qdrant(config, hits)

    return hits


def extract_seed_entity_candidates(v_hits: list, query_text: str = "") -> list[str]:
    """Extract distinct seed entity names from vector hits, prioritizing query-relevant entities."""
    candidates = []
    seen = set()
    query_lower = (query_text or "").lower()

    for v in v_hits[:3]:
        payload = getattr(v, "payload", {}) or {}
        chunk_ents = payload.get("entity_names") or []
        if not chunk_ents:
            single = payload.get("entity_name") or payload.get("title")
            if single:
                chunk_ents = [single]
        for ent in chunk_ents:
            if ent and isinstance(ent, str):
                trimmed = ent.strip()
                norm = trimmed.lower()
                if norm and norm not in seen:
                    seen.add(norm)
                    candidates.append(trimmed)

    # Sort entities so those mentioned directly in the query text rank first
    if query_lower:
        candidates.sort(
            key=lambda name: (
                0 if name.lower() in query_lower or query_lower in name.lower() else 1
            )
        )
    return candidates


def seed_graph_hits_from_vectors(
    v_hits: list,
    query_text: str,
    max_hops: int,
    tenant_id: str,
    max_seeds: int = 3,
    query_graph_fn=None,
    source_scope: dict | None = None,
) -> list[GraphHit]:
    """Traverse graph for up to max_seeds distinct entities discovered in top vector hits."""
    traverse_fn = query_graph_fn or query_graph
    # Only forward the scope when one is set, so injected traversal
    # functions with the pre-scope signature keep working unchanged.
    scope_kwargs = {"source_scope": source_scope} if source_scope else {}
    candidates = extract_seed_entity_candidates(v_hits, query_text)
    g_hits: list[GraphHit] = []
    seen_ids = set()

    for candidate in candidates[:max_seeds]:
        try:
            hits = traverse_fn(
                entity_name=candidate,
                max_hops=max_hops,
                tenant_id=tenant_id,
                **scope_kwargs,
            )
            for h in hits:
                if h.id not in seen_ids:
                    seen_ids.add(h.id)
                    g_hits.append(h)
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning(f"Failed graph traversal for seed '{candidate}': {exc}")

    if not g_hits and query_text and query_text.strip():
        try:
            hits = traverse_fn(
                entity_name=query_text.strip(),
                max_hops=max_hops,
                tenant_id=tenant_id,
                **scope_kwargs,
            )
            for h in hits:
                if h.id not in seen_ids:
                    seen_ids.add(h.id)
                    g_hits.append(h)
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning(
                f"Fallback query_graph failed for query '{query_text}': {exc}"
            )

    return g_hits
