"""Persistence layer for user-visible memories.

Single service layer over ``user_memories`` (migration
``007_user_memories.sql``), following the
:mod:`backend.services.sandbox_store` pattern. Every query is scoped
by both ``tenant_id`` and ``user_id`` — in this codebase the tenant id
returned by the gateway's ``get_tenant_id`` dependency *is* the
authenticated user id (see the RLS policies in migrations 005–007),
so routes pass it for both scopes.

Memories are temporal: ``valid_to`` is NULL while a memory is still
valid; :func:`expire_memory` soft-expires a memory by stamping
``valid_to`` instead of deleting the row.

All functions are synchronous Supabase calls; async callers wrap them
in ``asyncio.to_thread``.
"""

import logging
from datetime import UTC, datetime

import sentry_sdk

logger = logging.getLogger(__name__)

TABLE = "user_memories"

_COLUMNS = (
    "id, tenant_id, user_id, content, source, valid_from, valid_to, "
    "created_at, updated_at"
)

_SOURCES = ("chat", "manual", "import")


def public_view(row: dict) -> dict:
    """API-safe view of a user memory row."""
    return {
        "id": row.get("id"),
        "tenant_id": row.get("tenant_id"),
        "user_id": row.get("user_id"),
        "content": row.get("content") or "",
        "source": row.get("source") or "manual",
        "valid_from": row.get("valid_from"),
        "valid_to": row.get("valid_to"),
        "is_valid": row.get("valid_to") is None,
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
    }


def validate_memory_fields(data: dict) -> None:
    """Raise ValueError for empty content or an unknown source."""
    if data.get("content") is not None and not str(data["content"]).strip():
        raise ValueError("content must not be empty")
    if data.get("source") is not None and data["source"] not in _SOURCES:
        raise ValueError(f"source must be one of {_SOURCES}")


def create_memory(
    sb,
    tenant_id: str,
    user_id: str,
    content: str,
    source: str = "manual",
    valid_from: str | None = None,
) -> dict:
    """Insert a memory row for a tenant/user."""
    validate_memory_fields({"content": content, "source": source})
    payload: dict = {
        "tenant_id": tenant_id,
        "user_id": user_id,
        "content": content,
        "source": source,
    }
    if valid_from is not None:
        payload["valid_from"] = valid_from
    response = sb.table(TABLE).insert(payload).execute()
    rows = response.data or []
    if not rows:
        raise RuntimeError("User memory insert returned no row.")
    return rows[0]


def list_memories(
    sb, tenant_id: str, user_id: str, *, include_expired: bool = True
) -> list[dict]:
    """Return memory rows for a tenant/user, newest first."""
    response = (
        sb.table(TABLE)
        .select(_COLUMNS)
        .eq("tenant_id", tenant_id)
        .eq("user_id", user_id)
        .order("created_at", desc=True)
        .execute()
    )
    rows = response.data or []
    if include_expired:
        return rows
    return [row for row in rows if row.get("valid_to") is None]


def get_memory(sb, tenant_id: str, user_id: str, memory_id: str) -> dict | None:
    """Return one memory row scoped to the tenant/user, or None."""
    response = (
        sb.table(TABLE)
        .select(_COLUMNS)
        .eq("tenant_id", tenant_id)
        .eq("user_id", user_id)
        .eq("id", memory_id)
        .execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def update_memory(
    sb, tenant_id: str, user_id: str, memory_id: str, data: dict
) -> dict | None:
    """Update content/source/validity fields of a memory row."""
    validate_memory_fields(data)
    allowed = {
        k: data[k]
        for k in ("content", "source", "valid_from", "valid_to")
        if k in data and data[k] is not None
    }
    if not allowed:
        return get_memory(sb, tenant_id, user_id, memory_id)
    allowed["updated_at"] = datetime.now(UTC).isoformat()
    response = (
        sb.table(TABLE)
        .update(allowed)
        .eq("tenant_id", tenant_id)
        .eq("user_id", user_id)
        .eq("id", memory_id)
        .execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def expire_memory(sb, tenant_id: str, user_id: str, memory_id: str) -> dict | None:
    """Soft-expire a memory by stamping ``valid_to`` (row is kept)."""
    payload = {
        "valid_to": datetime.now(UTC).isoformat(),
        "updated_at": datetime.now(UTC).isoformat(),
    }
    response = (
        sb.table(TABLE)
        .update(payload)
        .eq("tenant_id", tenant_id)
        .eq("user_id", user_id)
        .eq("id", memory_id)
        .execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def delete_memory(sb, tenant_id: str, user_id: str, memory_id: str) -> bool:
    """Hard-delete a memory row; True when a row was removed."""
    response = (
        sb.table(TABLE)
        .delete()
        .eq("tenant_id", tenant_id)
        .eq("user_id", user_id)
        .eq("id", memory_id)
        .execute()
    )
    return bool(response.data)


def report_error(exc: Exception) -> None:
    """Report a non-fatal memory-store exception to Sentry."""
    sentry_sdk.capture_exception(exc)
    logger.error("Memory store error: %s", exc)
