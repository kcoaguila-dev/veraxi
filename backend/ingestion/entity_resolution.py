from typing import List, Dict, Any, Tuple
from backend.ingestion.chunk_embed import embed_text


def _find_matching_cluster(
    name: str, clusters: List[List[Dict[str, Any]]]
) -> List[Dict[str, Any]] | None:
    # Only import util when needed to avoid slow global imports
    from sentence_transformers import util

    name_emb = embed_text(name)

    for cluster in clusters:
        canonical_name = cluster[0].get("name", "")
        canonical_emb = embed_text(canonical_name)

        # Calculate cosine similarity between the two semantic vectors
        # util.cos_sim returns a 2D tensor, we extract the float value
        score = util.cos_sim(name_emb, canonical_emb).item()

        if score >= 0.90:
            return cluster
    return None


def _merge_cluster(cluster: List[Dict[str, Any]]) -> Dict[str, Any]:
    cluster.sort(key=lambda x: len(x.get("name", "")), reverse=True)
    canonical_ent = cluster[0].copy()

    merged_props = {}
    for ent in cluster:
        props = ent.get("properties", {})
        for k, v in props.items():
            if k not in merged_props:
                merged_props[k] = v

    canonical_ent["properties"] = merged_props
    return canonical_ent


def _group_entities_by_type(entities: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    type_groups: Dict[str, List[Dict[str, Any]]] = {}
    for ent in entities:
        ent_type = ent.get("type", "Unknown")
        type_groups.setdefault(ent_type, []).append(ent)
    return type_groups


def _cluster_entities(group: List[Dict[str, Any]]) -> List[List[Dict[str, Any]]]:
    clusters: List[List[Dict[str, Any]]] = []
    for ent in group:
        name = ent.get("name", "")
        matching_cluster = _find_matching_cluster(name, clusters)
        if matching_cluster is not None:
            matching_cluster.append(ent)
        else:
            clusters.append([ent])
    return clusters


def _process_clusters(
    clusters: List[List[Dict[str, Any]]],
    resolved_entities: List[Dict[str, Any]],
    alias_to_canonical: Dict[str, str],
):
    for cluster in clusters:
        merged = _merge_cluster(cluster)
        resolved_entities.append(merged)

        canonical_name = merged["name"]
        for ent in cluster:
            alias_to_canonical[ent["name"]] = canonical_name


def resolve_entities(entities: List[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], Dict[str, str]]:
    """
    Deduplication pass using native Python to collapse similar entities.
    Expects entities to have 'name' and 'type'.
    Returns a tuple of (resolved_entities, alias_to_canonical_mapping).
    """
    if not entities:
        return [], {}

    type_groups = _group_entities_by_type(entities)
    resolved_entities = []
    alias_to_canonical: Dict[str, str] = {}

    for group in type_groups.values():
        clusters = _cluster_entities(group)
        _process_clusters(clusters, resolved_entities, alias_to_canonical)

    return resolved_entities, alias_to_canonical
