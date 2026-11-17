"""Persistence layer for per-tenant external integrations.

This is the single service layer over the ``tenant_integrations``
Supabase table (migration ``005_integrations.sql``). Routes, the MCP
client manager, the OAuth service, and the OpenAPI importer all go
through here so secret handling stays in one place:

- Secrets are only ever stored as Fernet ciphertext via
  :mod:`backend.security.token_vault`.
- :func:`public_view` is the only shape API responses may use: it never
  includes ``encrypted_secrets`` and exposes only ``has_auth``.

All functions are synchronous Supabase calls; async callers wrap them in
``asyncio.to_thread`` (the pattern used by ``routes/api_keys.py``).
"""

import logging
import re
from datetime import UTC, datetime

import sentry_sdk

from backend.security.token_vault import decrypt_secrets, encrypt_secrets

logger = logging.getLogger(__name__)

TABLE = "tenant_integrations"

_SLUG_INVALID = re.compile(r"[^a-z0-9_-]+")
_SELECT_COLUMNS = (
    "id, tenant_id, kind, provider, slug, display_name, config, "
    "encrypted_secrets, token_expires_at, scopes, is_enabled, status, "
    "last_synced_at, created_at, updated_at"
)


def slugify(text: str) -> str:
    """Sanitize text into a ``[a-z0-9_-]+`` slug (may be empty)."""
    slug = _SLUG_INVALID.sub("-", (text or "").strip().lower()).strip("-_")
    return slug[:48].strip("-_") or ""


def unique_slug(sb, tenant_id: str, base: str) -> str:
    """Return ``base`` or ``base-2``, ``base-3``… unique for the tenant."""
    base = slugify(base) or "integration"
    existing = {
        row.get("slug")
        for row in list_integrations(sb, tenant_id, include_secrets=False)
    }
    if base not in existing:
        return base
    suffix = 2
    while f"{base}-{suffix}" in existing:
        suffix += 1
    return f"{base}-{suffix}"


def public_view(row: dict) -> dict:
    """API-safe view of an integration row (never includes secrets)."""
    return {
        "id": row.get("id"),
        "kind": row.get("kind"),
        "provider": row.get("provider"),
        "slug": row.get("slug"),
        "display_name": row.get("display_name"),
        "config": row.get("config") or {},
        "has_auth": bool(row.get("encrypted_secrets")),
        "token_expires_at": row.get("token_expires_at"),
        "scopes": row.get("scopes") or [],
        "is_enabled": bool(row.get("is_enabled", True)),
        "status": row.get("status") or "connected",
        "last_synced_at": row.get("last_synced_at"),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
    }


def decrypt_row_secrets(row: dict) -> dict:
    """Decrypt a row's secrets (server-side use only; never returned)."""
    return decrypt_secrets(row.get("encrypted_secrets"))


def list_integrations(sb, tenant_id: str, *, include_secrets: bool = True) -> list[dict]:
    """Return all integration rows for a tenant (raw rows)."""
    response = (
        sb.table(TABLE)
        .select(_SELECT_COLUMNS)
        .eq("tenant_id", tenant_id)
        .order("created_at", desc=True)
        .execute()
    )
    rows = response.data or []
    if include_secrets:
        return rows
    return [{k: v for k, v in row.items() if k != "encrypted_secrets"} for row in rows]


def list_enabled_integrations(sb, tenant_id: str) -> list[dict]:
    """Return enabled integration rows for a tenant (raw rows)."""
    return [
        row
        for row in list_integrations(sb, tenant_id)
        if row.get("is_enabled", True)
    ]


def get_integration(sb, tenant_id: str, integration_id: str) -> dict | None:
    """Return one raw integration row, or None."""
    response = (
        sb.table(TABLE)
        .select(_SELECT_COLUMNS)
        .eq("tenant_id", tenant_id)
        .eq("id", integration_id)
        .execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def get_integration_by_provider(sb, tenant_id: str, provider: str) -> dict | None:
    """Return the tenant's integration row for a provider, or None."""
    for row in list_integrations(sb, tenant_id):
        if row.get("provider") == provider:
            return row
    return None


def create_integration(
    sb,
    tenant_id: str,
    *,
    kind: str,
    provider: str,
    slug: str,
    display_name: str,
    config: dict | None = None,
    secrets: dict | None = None,
    scopes: list[str] | None = None,
    token_expires_at: str | None = None,
    status: str = "connected",
) -> dict:
    """Insert an integration row, encrypting secrets if provided."""
    data: dict = {
        "tenant_id": tenant_id,
        "kind": kind,
        "provider": provider,
        "slug": slug,
        "display_name": display_name,
        "config": config or {},
        "scopes": scopes or [],
        "status": status,
    }
    if secrets:
        data["encrypted_secrets"] = encrypt_secrets(secrets)
    if token_expires_at:
        data["token_expires_at"] = token_expires_at
    response = sb.table(TABLE).insert(data).execute()
    rows = response.data or []
    if not rows:
        raise RuntimeError("Integration insert returned no row.")
    return rows[0]


def update_integration(
    sb,
    tenant_id: str,
    integration_id: str,
    *,
    display_name: str | None = None,
    config: dict | None = None,
    secrets: dict | None = None,
    is_enabled: bool | None = None,
    status: str | None = None,
    token_expires_at: str | None = None,
    scopes: list[str] | None = None,
    last_synced_at: str | None = None,
) -> dict | None:
    """Update selected fields of an integration row; returns the row.

    ``secrets`` *replaces* the stored secret set (callers that merge do
    so before calling). ``config`` *replaces* the config object for the
    same reason — merge in the caller where partial updates are wanted.
    """
    data: dict = {"updated_at": datetime.now(UTC).isoformat()}
    if display_name is not None:
        data["display_name"] = display_name
    if config is not None:
        data["config"] = config
    if secrets is not None:
        data["encrypted_secrets"] = encrypt_secrets(secrets) if secrets else None
    if is_enabled is not None:
        data["is_enabled"] = is_enabled
    if status is not None:
        data["status"] = status
    if token_expires_at is not None:
        data["token_expires_at"] = token_expires_at
    if scopes is not None:
        data["scopes"] = scopes
    if last_synced_at is not None:
        data["last_synced_at"] = last_synced_at
    response = (
        sb.table(TABLE)
        .update(data)
        .eq("tenant_id", tenant_id)
        .eq("id", integration_id)
        .execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def delete_integration(sb, tenant_id: str, integration_id: str) -> bool:
    """Delete an integration row; True when a row was removed."""
    response = (
        sb.table(TABLE)
        .delete()
        .eq("tenant_id", tenant_id)
        .eq("id", integration_id)
        .execute()
    )
    return bool(response.data)


def report_error(exc: Exception) -> None:
    """Report a non-fatal integration-store exception to Sentry."""
    sentry_sdk.capture_exception(exc)
    logger.error("Integration store error: %s", exc)
