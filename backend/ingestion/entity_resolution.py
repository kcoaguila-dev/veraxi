from typing import List, Dict, Any
import difflib


def _find_matching_cluster(
    name: str, clusters: List[List[Dict[str, Any]]]
) -> List[Dict[str, Any]] | None:
    for cluster in clusters:
        canonical_name = cluster[0].get("name", "")
        similarity = difflib.SequenceMatcher(
            None, name.lower(), canonical_name.lower()
        ).ratio()
        if similarity >= 0.85:
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


def resolve_entities(entities: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Deduplication pass using native Python to collapse similar entities.
    Expects entities to have 'name' and 'type'.
    """
    if not entities:
        return []

    # Group entities by type first to avoid comparing apples to oranges
    type_groups: Dict[str, List[Dict[str, Any]]] = {}
    for ent in entities:
        ent_type = ent.get("type", "Unknown")
        type_groups.setdefault(ent_type, []).append(ent)

    resolved_entities = []

    for ent_type, group in type_groups.items():
        clusters: List[List[Dict[str, Any]]] = []

        for ent in group:
            name = ent.get("name", "")
            matching_cluster = _find_matching_cluster(name, clusters)

            if matching_cluster is not None:
                matching_cluster.append(ent)
            else:
                clusters.append([ent])

        # Merge each cluster into a single representative entity
        for cluster in clusters:
            resolved_entities.append(_merge_cluster(cluster))

    return resolved_entities
