from typing import Any

import unicodedata
import re

import numpy as np

from backend.ingestion.chunk_embed import embed_text, get_embedding_model


GENERIC_SUFFIXES = {
    "model",
    "formula",
    "equation",
    "theory",
    "method",
    "algorithm",
    "framework",
    "approach",
}


def normalize_name(name: str) -> str:
    """Casefold, NFKC, replace `_`, `-`, `.`, `'` with space, collapse whitespace, strip."""
    norm = unicodedata.normalize("NFKC", name).casefold()
    norm = re.sub(r"[_\-\.']", " ", norm)
    norm = re.sub(r"\s+", " ", norm).strip()
    return norm


def strip_generic_suffix(norm: str) -> str:
    """Strips trailing generic suffix token if at least one word remains."""
    words = norm.split()
    if len(words) > 1 and words[-1] in GENERIC_SUFFIXES:
        return " ".join(words[:-1])
    return norm


def acronym_of(norm: str) -> str | None:
    """Returns initials for phrases with >= 2 words after suffix stripping (e.g. "black scholes merton" -> "bsm")."""
    stripped = strip_generic_suffix(norm)
    words = stripped.split()
    if len(words) >= 2:
        return "".join(w[0] for w in words if w)
    return None


def is_acronym_match(a: str, b: str) -> bool:
    """True if one side (after suffix strip) is a 2-6 letter acronym matching acronym_of of the other side."""
    norm_a = strip_generic_suffix(normalize_name(a))
    norm_b = strip_generic_suffix(normalize_name(b))

    tokens_a = norm_a.split()
    tokens_b = norm_b.split()

    # Case 1: 'a' is the acronym of 'b'
    if len(tokens_a) == 1 and 2 <= len(tokens_a[0]) <= 6 and len(tokens_b) >= 2:
        if tokens_a[0] == acronym_of(norm_b):
            return True

    # Case 2: 'b' is the acronym of 'a'
    if len(tokens_b) == 1 and 2 <= len(tokens_b[0]) <= 6 and len(tokens_a) >= 2:
        if tokens_b[0] == acronym_of(norm_a):
            return True

    return False


def entity_key(tenant_id: str, label: str, name: str) -> str:
    """Formatted as `{tenant_id}::{label}::{strip_generic_suffix(normalize_name(name))}`."""
    norm = strip_generic_suffix(normalize_name(name))
    return f"{tenant_id}::{label}::{norm}"


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
    Groups by entity_key or is_acronym_match first, then uses batch embedding
    and vectorized cosine similarity for O(N) performance.
    """
    if not group:
        return []

    valid_group = [e for e in group if e.get("name", "").strip()]
    if not valid_group:
        return [[e] for e in group]

    # Pre-group by entity_key and acronym matches
    pre_clusters: list[list[dict[str, Any]]] = []

    for ent in valid_group:
        name = ent["name"]
        ent_type = ent.get("type", "Unknown")
        norm_name = normalize_name(name)
        key = entity_key("temp_tenant", ent_type, name)

        matched_cluster_idx = -1
        for idx, cluster in enumerate(pre_clusters):
            # Check if it matches the canonical/first element of the cluster
            for c_ent in cluster:
                c_name = c_ent["name"]
                c_norm = normalize_name(c_name)
                c_key = entity_key("temp_tenant", ent_type, c_name)

                if key == c_key or is_acronym_match(norm_name, c_norm):
                    matched_cluster_idx = idx
                    break

            if matched_cluster_idx != -1:
                break

        if matched_cluster_idx != -1:
            pre_clusters[matched_cluster_idx].append(ent)
        else:
            pre_clusters.append([ent])

    # Now we have pre_clusters. We extract the longest name from each pre_cluster as its canonical name
    # and embed those canonical names.
    canonical_names = []
    for cluster in pre_clusters:
        # Longest surface name as canonical for embedding
        longest_ent = max(cluster, key=lambda x: len(x.get("name", "")))
        canonical_names.append(longest_ent["name"].strip())

    unique_names = list(dict.fromkeys(canonical_names))

    if len(unique_names) == 1:
        # All valid entities mapped to the same canonical name cluster
        # which means all pre_clusters map to the same name (should only be 1 pre_cluster)
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

    # Vectorized clustering over unique canonical names
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

    # Map canonical name to final cluster index
    name_to_cluster_idx: dict[str, int] = {}
    for idx, cluster_names in enumerate(name_clusters):
        for n in cluster_names:
            name_to_cluster_idx[n] = idx

    # Group original entity dicts into clusters using their pre_cluster
    final_clusters: list[list[dict[str, Any]]] = [[] for _ in range(len(name_clusters))]
    for cluster, canonical_name in zip(pre_clusters, canonical_names):
        idx = name_to_cluster_idx[canonical_name]
        final_clusters[idx].extend(cluster)

    # Add back any entities with empty names as isolated clusters
    empty_ents = [e for e in group if not e.get("name", "").strip()]
    for e in empty_ents:
        final_clusters.append([e])

    return [c for c in final_clusters if c]


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
