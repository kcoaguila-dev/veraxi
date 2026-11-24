"""Shared Code Mode source-scope parsing for graph and vector retrieval.

Single source of truth for extracting ``(repo_keys, source_ids)`` from
a ``source_scope`` dictionary. Both :mod:`backend.storage.qdrant_client`
and :mod:`backend.mcp_server.tools.query_graph` import from here so
scope semantics can never drift between Neo4j and Qdrant.
"""


def _collect_scope_dict(
    scope: dict | None,
    repo_keys: list[str],
    source_ids: list[str],
) -> None:
    if not isinstance(scope, dict):
        return
    for key, bucket in (("repo_key", repo_keys), ("source_id", source_ids)):
        value = scope.get(key)
        if isinstance(value, str) and value and value not in bucket:
            bucket.append(value)
        plural = scope.get(f"{key}s")
        if isinstance(plural, (list, tuple)):
            for item in plural:
                if isinstance(item, str) and item and item not in bucket:
                    bucket.append(item)


def scope_filter_values(
    source_scope: dict | None,
) -> tuple[list[str], list[str]]:
    """Extract ``(repo_keys, source_ids)`` from a Code Mode ``source_scope``.

    Accepts ``repo_key`` (str) / ``repo_keys`` (list) and
    ``source_id`` (str) / ``source_ids`` (list); a ``selected_sources``
    sub-dict in the same shapes is merged in. A ``selected_sources``
    list (the shape the sources pill produces from
    ``GET /api/admin/sources``) contributes its string entries as
    source ids and any dict entries in the shapes above. Anything
    else is ignored.
    """
    repo_keys: list[str] = []
    source_ids: list[str] = []
    if not isinstance(source_scope, dict):
        return repo_keys, source_ids

    _collect_scope_dict(source_scope, repo_keys, source_ids)
    selected = source_scope.get("selected_sources")
    if isinstance(selected, (list, tuple)):
        for item in selected:
            if isinstance(item, str):
                if item and item not in source_ids:
                    source_ids.append(item)
            else:
                _collect_scope_dict(item, repo_keys, source_ids)
    else:
        _collect_scope_dict(selected, repo_keys, source_ids)
    return repo_keys, source_ids
