import logging
import re
import sentry_sdk

from backend.config import get_config
from backend.retrieval.merge_rank import GraphHit
from backend.storage.neo4j_client import Neo4jStorageClient

logger = logging.getLogger(__name__)

MAX_ALLOWED_HOPS = 3


def _build_query_graph_params(entity_name: str, tenant_id: str) -> dict:
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
                        if k not in h.payload or not h.payload[k]:
                            h.payload[k] = v
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.warning(f"Failed to hydrate graph hits from Qdrant payloads: {exc}")


def query_graph(
    entity_name: str, max_hops: int = 2, tenant_id: str = "default"
) -> list[GraphHit]:
    """
    Perform a parameterized Cypher traversal from a starting entity out to max_hops.
    Returns results as GraphHit objects ready for merge_rank.
    No string-concatenated queries for user inputs.
    """
    config = get_config()
    neo4j = Neo4jStorageClient.from_config(config)

    # max_hops is an integer and controlled/validated by us (or typed as int from MCP tool).
    # We must ensure it's a positive integer to avoid injection.
    max_hops = min(max(1, int(max_hops)), MAX_ALLOWED_HOPS)

    params = _build_query_graph_params(entity_name, tenant_id)

    # We parameterize all user inputs and rank candidate start nodes by match quality:
    # Tier 0: Exact match on name or alias
    # Tier 1: Token match or whole-phrase boundary containment (raw and punctuation-normalized)
    # Tier 2: Substring match on longer entity names
    query = f"""
    MATCH (start)
    WHERE (start:Entity OR NOT start:Chunk)
      AND start.tenant_id = $tenant_id
      AND (
        start.name = $entity_name
        OR toLower(start.name) = $lower_name
        OR any(a IN coalesce(start.aliases, []) WHERE toLower(a) = $lower_name)
        OR (size(start.name) >= 3 AND toLower(start.name) IN $query_tokens)
        OR any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND toLower(a) IN $query_tokens)
        OR (size(start.name) >= 3 AND $padded_norm_query CONTAINS (' ' + replace(replace(replace(toLower(start.name), '-', ' '), '.', ' '), '_', ' ') + ' '))
        OR (size(start.name) >= 3 AND $padded_raw_query CONTAINS (' ' + toLower(start.name) + ' '))
        OR any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND $padded_norm_query CONTAINS (' ' + replace(replace(replace(toLower(a), '-', ' '), '.', ' '), '_', ' ') + ' '))
        OR any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND $padded_raw_query CONTAINS (' ' + toLower(a) + ' '))
        OR (size($lower_name) >= 4 AND toLower(start.name) CONTAINS $lower_name)
      )
    WITH start,
         CASE
           WHEN start.name = $entity_name OR toLower(start.name) = $lower_name THEN 0
           WHEN any(a IN coalesce(start.aliases, []) WHERE toLower(a) = $lower_name) THEN 0
           WHEN size(start.name) >= 3 AND $padded_norm_query CONTAINS (' ' + replace(replace(replace(toLower(start.name), '-', ' '), '.', ' '), '_', ' ') + ' ') THEN 1
           WHEN size(start.name) >= 3 AND $padded_raw_query CONTAINS (' ' + toLower(start.name) + ' ') THEN 1
           WHEN any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND $padded_norm_query CONTAINS (' ' + replace(replace(replace(toLower(a), '-', ' '), '.', ' '), '_', ' ') + ' ')) THEN 1
           WHEN any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND $padded_raw_query CONTAINS (' ' + toLower(a) + ' ')) THEN 1
           WHEN size(start.name) >= 3 AND toLower(start.name) IN $query_tokens THEN 1
           WHEN any(a IN coalesce(start.aliases, []) WHERE size(a) >= 2 AND toLower(a) IN $query_tokens) THEN 1
           ELSE 2
         END AS match_tier
    ORDER BY match_tier ASC, size(start.name) DESC
    LIMIT 5
    MATCH (start)-[rels*1..{max_hops}]-(end)
    WHERE end.tenant_id = $tenant_id
    WITH start, end, last(rels) AS last_rel, size(rels) AS hop_distance,
         size([r IN rels WHERE type(r) IN ['MENTIONED_WITH', 'ASSOCIATED_WITH', 'RELATED_TO']]) AS noisy_hops
    ORDER BY hop_distance ASC, noisy_hops ASC
    WITH DISTINCT start, end, head(collect(last_rel)) AS last_rel, min(hop_distance) AS min_hops, min(noisy_hops) AS min_noisy_hops
    ORDER BY min_hops ASC, min_noisy_hops ASC
    LIMIT 50
    UNWIND (CASE WHEN size(coalesce(end.qdrant_point_ids, [])) > 0 THEN end.qdrant_point_ids ELSE ['neo4j:' + toString(end.id)] END) AS qid
    RETURN DISTINCT end.id AS id,
           start.name AS source_entity,
           qid AS qdrant_point_id,
           labels(end) AS labels,
           properties(end) AS props,
           type(last_rel) AS relation_type,
           last_rel.last_confirmed_at AS last_confirmed_at,
           last_rel.source AS relation_source,
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
            payload = row.get("props", {}).copy() if isinstance(row.get("props"), dict) else {}
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
) -> list[GraphHit]:
    """Traverse graph for up to max_seeds distinct entities discovered in top vector hits."""
    traverse_fn = query_graph_fn or query_graph
    candidates = extract_seed_entity_candidates(v_hits, query_text)
    g_hits: list[GraphHit] = []
    seen_ids = set()

    for candidate in candidates[:max_seeds]:
        try:
            hits = traverse_fn(
                entity_name=candidate,
                max_hops=max_hops,
                tenant_id=tenant_id,
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
            )
            for h in hits:
                if h.id not in seen_ids:
                    seen_ids.add(h.id)
                    g_hits.append(h)
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.warning(f"Fallback query_graph failed for query '{query_text}': {exc}")

    return g_hits
