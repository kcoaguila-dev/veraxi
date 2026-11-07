from typing import Any

import unicodedata
import re

import numpy as np

from backend.ingestion.chunk_embed import embed_text, get_embedding_model


GENERIC_SUFFIXES = {
    # Academic / analytical suffixes
    "model",
    "formula",
    "equation",
    "theory",
    "method",
    "algorithm",
    "framework",
    "approach",
    # Corporate / legal suffixes
    "inc",
    "incorporated",
    "corp",
    "corporation",
    "ltd",
    "limited",
    "llc",
    "plc",
    "co",
    "company",
    "group",
    "holdings",
    # Institutional / organizational structure suffixes
    "system",
    "board",
}

_PARENTHETICAL_RE = re.compile(
    r"(?:([A-Z][A-Za-z0-9\-]+(?:\s+[A-Z][A-Za-z0-9\-]+)*)|(?:^|[\s,;])([A-Za-z0-9\-]+))\s*\(\s*(?:also\s+known\s+as\s+|commonly\s+called\s+|hereafter\s+|or\s+)?([A-Za-z][A-Za-z0-9\-\s]{1,35}?)\s*\)"
)


def extract_in_text_aliases(text: str) -> dict[str, set[str]]:
    """
    Domain-agnostic Schwartz-Hearst style parenthetical & apposition alias extractor.
    Detects patterns like:
      - "Federal Reserve (the Fed)"
      - "Taiwan Semiconductor Manufacturing Company (TSMC)"
      - "Acetaminophen (commonly called Tylenol)"
      - "Epidermal growth factor receptor (EGFR)"
    Returns a bidirectional mapping of normalized surface forms to their discovered aliases.
    """
    alias_map: dict[str, set[str]] = {}
    if not text:
        return alias_map

    for match in _PARENTHETICAL_RE.finditer(text):
        long_form = (match.group(1) or match.group(2) or "").strip()
        short_form = match.group(3).strip()
        norm_long = strip_generic_suffix(normalize_name(long_form))
        norm_short = strip_generic_suffix(normalize_name(short_form))
        if not norm_long or not norm_short or norm_long == norm_short:
            continue
        # Reject pure numbers or years in parentheses like "Revenue (2024)"
        if norm_short.isdigit() or len(norm_short) < 2:
            continue
        alias_map.setdefault(norm_long, set()).add(short_form)
        alias_map.setdefault(norm_short, set()).add(long_form)

    return alias_map


def normalize_name(name: str) -> str:
    """Casefold, NFKC, replace `_`, `-`, `.`, `'` with space, collapse whitespace, strip."""
    norm = unicodedata.normalize("NFKC", name).casefold()
    norm = re.sub(r"[_\-\.']", " ", norm)
    norm = re.sub(r"\s+", " ", norm).strip()
    return norm


def strip_generic_suffix(norm: str) -> str:
    """Strips leading articles ('the', 'a', 'an') and trailing generic/corporate/institutional suffixes."""
    words = norm.split()
    if len(words) > 1 and words[0] in {"the", "a", "an"}:
        words = words[1:]

    while len(words) > 1 and words[-1] in GENERIC_SUFFIXES:
        words = words[:-1]

    return " ".join(words)


def acronym_of(norm: str) -> str | None:
    """Returns initials for phrases with >= 2 words after suffix stripping (e.g. "black scholes merton" -> "bsm")."""
    stripped = strip_generic_suffix(norm)
    words = stripped.split()
    if len(words) >= 2:
        return "".join(w[0] for w in words if w)
    return None


def acronym_candidates(norm: str) -> set[str]:
    """Returns possible acronyms for a phrase (both with and without generic suffix stripping)."""
    candidates = set()
    raw_words = norm.split()
    if len(raw_words) >= 2:
        candidates.add("".join(w[0] for w in raw_words if w))

    stripped = strip_generic_suffix(norm)
    stripped_words = stripped.split()
    if len(stripped_words) >= 2:
        candidates.add("".join(w[0] for w in stripped_words if w))

    return {c for c in candidates if 2 <= len(c) <= 6}


def is_acronym_match(a: str, b: str) -> bool:
    """True if one side is a 2-6 letter acronym matching acronym candidates of the other side."""
    norm_a = normalize_name(a)
    norm_b = normalize_name(b)
    stripped_a = strip_generic_suffix(norm_a)
    stripped_b = strip_generic_suffix(norm_b)

    tokens_a = stripped_a.split()
    tokens_b = stripped_b.split()

    # Case 1: 'a' is the acronym of 'b'
    if (
        len(tokens_a) == 1
        and 2 <= len(tokens_a[0]) <= 6
        and (
            tokens_a[0] in acronym_candidates(norm_b)
            or tokens_a[0] in acronym_candidates(stripped_b)
        )
    ):
        return True

    # Case 2: 'b' is the acronym of 'a'
    return (
        len(tokens_b) == 1
        and 2 <= len(tokens_b[0]) <= 6
        and (
            tokens_b[0] in acronym_candidates(norm_a)
            or tokens_b[0] in acronym_candidates(stripped_a)
        )
    )


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

    from backend.config import get_config

    threshold = get_config().entity_resolution_threshold
    name_emb = np.array(embed_text(name), dtype=np.float32)
    name_norm = np.linalg.norm(name_emb)
    if name_norm > 0:
        name_emb = name_emb / name_norm

    for cluster in clusters:
        if not cluster:
            continue
        canonical_name = cluster[0].get("name", "")
        canonical_emb = np.array(embed_text(canonical_name), dtype=np.float32)
        can_norm = np.linalg.norm(canonical_emb)
        if can_norm > 0:
            canonical_emb = canonical_emb / can_norm
        score = float(np.dot(name_emb, canonical_emb))
        if score >= threshold:
            return cluster
    return None


def _entity_norm_forms(ent: dict[str, Any]) -> set[str]:
    """Returns all normalized and raw lowercase surface forms (name + aliases) for an entity."""
    forms: set[str] = set()
    raw_names = [ent.get("name", "")] + list(ent.get("aliases", []) or [])
    for raw in raw_names:
        if isinstance(raw, str) and raw.strip():
            forms.add(raw.strip().lower())
            norm = strip_generic_suffix(normalize_name(raw))
            if norm:
                forms.add(norm)
    return forms


def _entities_share_alias_or_acronym(
    ent_a: dict[str, Any], ent_b: dict[str, Any]
) -> bool:
    """True if two entities share any normalized name/alias or acronym match across any of their forms."""
    forms_a = _entity_norm_forms(ent_a)
    forms_b = _entity_norm_forms(ent_b)
    if forms_a & forms_b:
        return True
    for fa in forms_a:
        for fb in forms_b:
            if is_acronym_match(fa, fb):
                return True
    return False


def _merge_cluster(cluster: list[dict[str, Any]]) -> dict[str, Any]:
    cluster.sort(key=lambda x: len(x.get("name", "")), reverse=True)
    canonical_ent = cluster[0].copy()

    merged_props = {}
    all_aliases: list[str] = []
    seen_lower: set[str] = set()

    for ent in cluster:
        name = ent.get("name", "").strip()
        if name and name.lower() not in seen_lower:
            seen_lower.add(name.lower())
            all_aliases.append(name)
        for alias in ent.get("aliases", []) or []:
            if (
                isinstance(alias, str)
                and alias.strip()
                and alias.strip().lower() not in seen_lower
            ):
                seen_lower.add(alias.strip().lower())
                all_aliases.append(alias.strip())

        props = ent.get("properties", {})
        for k, v in props.items():
            if k not in merged_props:
                merged_props[k] = v

    canonical_ent["properties"] = merged_props
    canonical_ent["aliases"] = all_aliases

    all_source_point_ids: list[str] = []
    seen_pids: set[str] = set()
    for ent in cluster:
        for pid in ent.get("source_point_ids", []) or []:
            if pid and pid not in seen_pids:
                seen_pids.add(pid)
                all_source_point_ids.append(pid)
    if all_source_point_ids:
        canonical_ent["source_point_ids"] = all_source_point_ids

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
    Groups by entity_key, shared aliases, or is_acronym_match first, then uses batch embedding
    and vectorized cosine similarity for O(N) performance.
    """
    if not group:
        return []

    valid_group = [e for e in group if e.get("name", "").strip()]
    if not valid_group:
        return [[e] for e in group]

    # Pre-group by entity_key, alias intersection, and acronym matches via inverted index
    pre_clusters: list[list[dict[str, Any]]] = []
    form_to_cluster_idx: dict[str, int] = {}
    acronym_to_cluster_idx: dict[str, int] = {}

    for ent in valid_group:
        forms = _entity_norm_forms(ent)
        matched_cluster_idx = -1

        # Direct alias/form match via inverted index
        for f in forms:
            if f in form_to_cluster_idx:
                matched_cluster_idx = form_to_cluster_idx[f]
                break

        # Acronym matching via inverted index
        if matched_cluster_idx == -1:
            for f in forms:
                for acr in acronym_candidates(f):
                    if acr in acronym_to_cluster_idx:
                        matched_cluster_idx = acronym_to_cluster_idx[acr]
                        break
                if f in acronym_to_cluster_idx:
                    matched_cluster_idx = acronym_to_cluster_idx[f]
                    break
                if matched_cluster_idx != -1:
                    break

        if matched_cluster_idx != -1:
            pre_clusters[matched_cluster_idx].append(ent)
        else:
            matched_cluster_idx = len(pre_clusters)
            pre_clusters.append([ent])

        for f in forms:
            form_to_cluster_idx[f] = matched_cluster_idx
            for acr in acronym_candidates(f):
                acronym_to_cluster_idx[acr] = matched_cluster_idx
            if len(f.split()) == 1 and 2 <= len(f) <= 6:
                acronym_to_cluster_idx[f] = matched_cluster_idx

    # Extract the longest name from each pre_cluster as its canonical name for embedding
    canonical_names = []
    for cluster in pre_clusters:
        longest_ent = max(cluster, key=lambda x: len(x.get("name", "")))
        canonical_names.append(longest_ent["name"].strip())

    unique_names = list(dict.fromkeys(canonical_names))

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

    # Vectorized clustering over unique canonical names
    name_clusters: list[list[str]] = []
    cluster_seed_vectors: list[np.ndarray] = []

    from backend.config import get_config

    threshold = get_config().entity_resolution_threshold

    for name in unique_names:
        emb = name_to_emb[name]
        matched = False

        if cluster_seed_vectors:
            cluster_mat = np.stack(cluster_seed_vectors)
            scores = np.dot(cluster_mat, emb)

            for idx, score in enumerate(scores):
                if score >= threshold:
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
            for alias in ent.get("aliases", []) or []:
                if isinstance(alias, str) and alias.strip():
                    alias_to_canonical[alias.strip()] = canonical_name


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
