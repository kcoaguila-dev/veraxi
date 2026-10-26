from typing import Any
import numpy as np

from backend.ingestion.chunk_embed import embed_text, get_embedding_model


def _find_matching_cluster(
    name: str, clusters: list[list[dict[str, Any]]]
) -> list[dict[str, Any]] | None:
    """Find matching cluster for an entity name (fallback / compatibility helper)."""
    if not clusters or not name:
        return None

    stripped_name = name.strip()
    lower_name = stripped_name.lower()

    # Fast check: exact or case-insensitive match against cluster canonical names
    for cluster in clusters:
        if not cluster:
            continue
        c_name = cluster[0].get("name", "").strip()
        if c_name.lower() == lower_name:
            return cluster

    from sentence_transformers import util

    name_emb = embed_text(name)
    for cluster in clusters:
        if not cluster:
            continue
        canonical_name = cluster[0].get("name", "")
        canonical_emb = embed_text(canonical_name)
        score = util.cos_sim(name_emb, canonical_emb).item()
        if score >= 0.90:
            return cluster
    return None


def _merge_cluster(cluster: list[dict[str, Any]]) -> dict[str, Any]:
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


def _group_entities_by_type(
    entities: list[dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
    type_groups: dict[str, list[dict[str, Any]]] = {}
    for ent in entities:
        ent_type = ent.get("type", "Unknown")
        type_groups.setdefault(ent_type, []).append(ent)
    return type_groups


def _cluster_entities(group: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    """
    Cluster entities within a single type group.
    Uses batch embedding and vectorized cosine similarity for O(N) performance
    instead of quadratic O(N^2) individual model forward passes.
    """
    if not group:
        return []

    valid_group = [e for e in group if e.get("name", "").strip()]
    if not valid_group:
        return [[e] for e in group]

    # Preserve order while gathering unique names
    unique_names = list(dict.fromkeys(e["name"].strip() for e in valid_group))

    if len(unique_names) == 1:
        return [valid_group]

    # Pre-compute normalized embeddings in batches
    model = get_embedding_model()
    raw_embeddings = model.encode(
        unique_names, batch_size=64, normalize_embeddings=True
    )
    if isinstance(raw_embeddings, list):
        embeddings = np.array(raw_embeddings)
    elif hasattr(raw_embeddings, "cpu"):
        embeddings = raw_embeddings.cpu().numpy()
    else:
        embeddings = np.asarray(raw_embeddings)

    name_to_emb: dict[str, np.ndarray] = {
        name: embeddings[i] for i, name in enumerate(unique_names)
    }

    # Vectorized clustering over unique names
    name_clusters: list[list[str]] = []
    cluster_seed_vectors: list[np.ndarray] = []

    for name in unique_names:
        emb = name_to_emb[name]
        matched = False

        if cluster_seed_vectors:
            cluster_mat = np.stack(cluster_seed_vectors)
            # Dot product of L2-normalized vectors == cosine similarity
            scores = np.dot(cluster_mat, emb)

            for idx, score in enumerate(scores):
                if score >= 0.90:
                    name_clusters[idx].append(name)
                    matched = True
                    break

        if not matched:
            name_clusters.append([name])
            cluster_seed_vectors.append(emb)

    # Map unique name to cluster index
    name_to_cluster_idx: dict[str, int] = {}
    for idx, cluster_names in enumerate(name_clusters):
        for n in cluster_names:
            name_to_cluster_idx[n] = idx

    # Group original entity dicts into clusters
    clusters: list[list[dict[str, Any]]] = [[] for _ in range(len(name_clusters))]
    for ent in valid_group:
        n = ent["name"].strip()
        idx = name_to_cluster_idx[n]
        clusters[idx].append(ent)

    # Add back any entities with empty names as isolated clusters
    empty_ents = [e for e in group if not e.get("name", "").strip()]
    for e in empty_ents:
        clusters.append([e])

    return [c for c in clusters if c]


def _process_clusters(
    clusters: list[list[dict[str, Any]]],
    resolved_entities: list[dict[str, Any]],
    alias_to_canonical: dict[str, str],
):
    for cluster in clusters:
        merged = _merge_cluster(cluster)
        resolved_entities.append(merged)

        canonical_name = merged["name"]
        for ent in cluster:
            alias_to_canonical[ent["name"]] = canonical_name


def resolve_entities(
    entities: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, str]]:
    """
    Deduplication pass using native Python and vectorized embeddings to collapse similar entities.
    Expects entities to have 'name' and 'type'.
    Returns a tuple of (resolved_entities, alias_to_canonical_mapping).
    """
    if not entities:
        return [], {}

    type_groups = _group_entities_by_type(entities)
    resolved_entities: list[dict[str, Any]] = []
    alias_to_canonical: dict[str, str] = {}

    for group in type_groups.values():
        clusters = _cluster_entities(group)
        _process_clusters(clusters, resolved_entities, alias_to_canonical)

    return resolved_entities, alias_to_canonical
