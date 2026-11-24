"""Persistence layer for per-tenant sandbox configs and sessions.

Single service layer over ``tenant_sandbox_configs`` and
``sandbox_sessions`` (migration ``006_sandboxes.sql``), following the
:mod:`backend.services.integration_store` pattern:

- Secrets are only ever stored as Fernet ciphertext via
  :mod:`backend.security.token_vault`.
- :func:`public_view` is the only shape API responses may use for
  configs: it never includes ``encrypted_secrets`` and exposes only
  ``has_secrets``.

All functions are synchronous Supabase calls; async callers wrap them
in ``asyncio.to_thread``.
"""

import logging
from datetime import UTC, datetime

import sentry_sdk

from backend.security.token_vault import decrypt_secrets, encrypt_secrets

logger = logging.getLogger(__name__)

CONFIG_TABLE = "tenant_sandbox_configs"
SESSION_TABLE = "sandbox_sessions"

_CONFIG_COLUMNS = (
    "id, tenant_id, provider, display_name, base_image, cpu_cores, "
    "memory_mb, disk_gb, idle_timeout_sec, max_session_sec, "
    "autonomy_mode, egress_mode, allowed_domains, isolate_git_branch, "
    "config, encrypted_secrets, is_active, created_at, updated_at"
)
_SESSION_COLUMNS = (
    "id, tenant_id, config_id, project_id, chat_id, "
    "external_sandbox_id, status, git_branch, last_active_at, created_at"
)

_PROVIDERS = ("disabled", "modal", "e2b", "remote_mcp", "local_runner")
_AUTONOMY = ("ask_all", "auto_read_test", "auto_workspace_writes", "autonomous")
_EGRESS = ("offline", "allowlist", "unrestricted")


def public_view(row: dict) -> dict:
    """API-safe view of a sandbox config row (never includes secrets)."""
    return {
        "id": row.get("id"),
        "tenant_id": row.get("tenant_id"),
        "provider": row.get("provider") or "disabled",
        "display_name": row.get("display_name") or "",
        "base_image": row.get("base_image") or "polyglot",
        "cpu_cores": row.get("cpu_cores") or 2,
        "memory_mb": row.get("memory_mb") or 4096,
        "disk_gb": row.get("disk_gb") or 10,
        "idle_timeout_sec": row.get("idle_timeout_sec") or 900,
        "max_session_sec": row.get("max_session_sec") or 3600,
        "autonomy_mode": row.get("autonomy_mode") or "auto_read_test",
        "egress_mode": row.get("egress_mode") or "allowlist",
        "allowed_domains": row.get("allowed_domains") or [],
        "isolate_git_branch": bool(row.get("isolate_git_branch", True)),
        "config": row.get("config") or {},
        "has_secrets": bool(row.get("encrypted_secrets")),
        "is_active": bool(row.get("is_active", True)),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
    }


def session_public_view(row: dict) -> dict:
    """API-safe view of a sandbox session row."""
    return {
        "id": row.get("id"),
        "tenant_id": row.get("tenant_id"),
        "config_id": row.get("config_id"),
        "project_id": row.get("project_id"),
        "chat_id": row.get("chat_id"),
        "external_sandbox_id": row.get("external_sandbox_id") or "",
        "status": row.get("status") or "starting",
        "git_branch": row.get("git_branch") or "",
        "last_active_at": row.get("last_active_at"),
        "created_at": row.get("created_at"),
    }


def decrypt_row_secrets(row: dict) -> dict:
    """Decrypt a config row's secrets (server-side use only)."""
    return decrypt_secrets(row.get("encrypted_secrets"))


def validate_config_fields(data: dict) -> None:
    """Raise ValueError for out-of-enum config values."""
    if data.get("provider") is not None and data["provider"] not in _PROVIDERS:
        raise ValueError(f"provider must be one of {_PROVIDERS}")
    if data.get("autonomy_mode") is not None and data["autonomy_mode"] not in _AUTONOMY:
        raise ValueError(f"autonomy_mode must be one of {_AUTONOMY}")
    if data.get("egress_mode") is not None and data["egress_mode"] not in _EGRESS:
        raise ValueError(f"egress_mode must be one of {_EGRESS}")


def get_config(sb, tenant_id: str) -> dict | None:
    """Return the tenant's raw sandbox config row, or None."""
    response = (
        sb.table(CONFIG_TABLE).select(_CONFIG_COLUMNS)
        .eq("tenant_id", tenant_id).execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def upsert_config(sb, tenant_id: str, data: dict, secrets: dict | None = None) -> dict:
    """Create or update the tenant's sandbox config row.

    ``secrets=None`` leaves stored secrets untouched; a dict *replaces*
    them (encrypted); an empty dict clears them.
    """
    validate_config_fields(data)
    allowed = {
        k: data[k] for k in (
            "provider", "display_name", "base_image", "cpu_cores",
            "memory_mb", "disk_gb", "idle_timeout_sec", "max_session_sec",
            "autonomy_mode", "egress_mode", "allowed_domains",
            "isolate_git_branch", "config", "is_active",
        ) if k in data and data[k] is not None
    }
    existing = get_config(sb, tenant_id)
    if secrets is not None:
        allowed["encrypted_secrets"] = encrypt_secrets(secrets) if secrets else None
    if existing:
        allowed["updated_at"] = datetime.now(UTC).isoformat()
        response = (
            sb.table(CONFIG_TABLE).update(allowed)
            .eq("tenant_id", tenant_id).execute()
        )
        rows = response.data or []
        return rows[0] if rows else {**existing, **allowed}
    allowed["tenant_id"] = tenant_id
    response = sb.table(CONFIG_TABLE).insert(allowed).execute()
    rows = response.data or []
    if not rows:
        raise RuntimeError("Sandbox config insert returned no row.")
    return rows[0]


def list_sessions(sb, tenant_id: str) -> list[dict]:
    """Return raw session rows for a tenant."""
    response = (
        sb.table(SESSION_TABLE).select(_SESSION_COLUMNS)
        .eq("tenant_id", tenant_id).order("created_at", desc=True).execute()
    )
    return response.data or []


def get_session(sb, tenant_id: str, session_id: str) -> dict | None:
    response = (
        sb.table(SESSION_TABLE).select(_SESSION_COLUMNS)
        .eq("tenant_id", tenant_id).eq("id", session_id).execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def create_session(sb, tenant_id: str, data: dict) -> dict:
    payload = {"tenant_id": tenant_id, **data}
    response = sb.table(SESSION_TABLE).insert(payload).execute()
    rows = response.data or []
    if not rows:
        raise RuntimeError("Sandbox session insert returned no row.")
    return rows[0]


def update_session(sb, tenant_id: str, session_id: str, data: dict) -> dict | None:
    response = (
        sb.table(SESSION_TABLE).update(data)
        .eq("tenant_id", tenant_id).eq("id", session_id).execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def delete_session(sb, tenant_id: str, session_id: str) -> bool:
    response = (
        sb.table(SESSION_TABLE).delete()
        .eq("tenant_id", tenant_id).eq("id", session_id).execute()
    )
    return bool(response.data)


def report_error(exc: Exception) -> None:
    """Report a non-fatal sandbox-store exception to Sentry."""
    sentry_sdk.capture_exception(exc)
    logger.error("Sandbox store error: %s", exc)
