"""Persistence layer for GitHub App installations and indexed repositories.

Operates on ``github_app_installations`` and ``github_app_repos`` (migration
``008_github_app.sql``). User-to-server OAuth tokens are encrypted/decrypted
exclusively via :mod:`backend.security.token_vault` and never returned in
public API views.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta
from typing import Any

import sentry_sdk

from backend.security.token_vault import decrypt_secrets, encrypt_secrets

logger = logging.getLogger(__name__)

INSTALLATIONS_TABLE = "github_app_installations"
REPOS_TABLE = "github_app_repos"

_INSTALLATION_COLUMNS = (
    "id, tenant_id, installation_id, github_account_id, github_account_login, "
    "github_account_type, repository_selection, permissions, status, "
    "encrypted_user_tokens, user_token_expires_at, created_at, updated_at"
)
_REPO_COLUMNS = (
    "id, tenant_id, installation_id, github_repo_id, repo_full_name, "
    "default_branch, is_private, auto_sync_on_push, index_status, "
    "last_indexed_sha, last_indexed_at, last_error, dependencies_snapshot, "
    "created_at, updated_at"
)


def public_installation_view(row: dict[str, Any]) -> dict[str, Any]:
    """API-safe representation of an installation (never includes encrypted tokens)."""
    return {
        "id": row.get("id"),
        "installation_id": row.get("installation_id"),
        "account_id": row.get("github_account_id"),
        "account_login": row.get("github_account_login"),
        "account_type": row.get("github_account_type"),
        "repository_selection": row.get("repository_selection") or "selected",
        "permissions": row.get("permissions") or {},
        "status": row.get("status") or "active",
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
    }


def decrypt_user_tokens(row: dict[str, Any]) -> dict[str, Any]:
    """Decrypt user-to-server OAuth token bundle for server-side use only."""
    return decrypt_secrets(row.get("encrypted_user_tokens"))


def token_expires_at_iso(expires_in: int | str | None) -> str | None:
    if not expires_in:
        return None
    return (datetime.now(UTC) + timedelta(seconds=int(expires_in))).isoformat()


def user_token_expired(row: dict[str, Any]) -> bool:
    raw = row.get("user_token_expires_at")
    if not raw:
        return False
    try:
        parsed = datetime.fromisoformat(str(raw))
    except ValueError:
        return False
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed <= datetime.now(UTC) + timedelta(seconds=60)


def list_installations(sb: Any, tenant_id: str) -> list[dict[str, Any]]:
    resp = (
        sb.table(INSTALLATIONS_TABLE)
        .select(_INSTALLATION_COLUMNS)
        .eq("tenant_id", tenant_id)
        .order("created_at", desc=True)
        .execute()
    )
    return list(resp.data or [])


def get_installation(
    sb: Any, tenant_id: str, installation_id: int
) -> dict[str, Any] | None:
    resp = (
        sb.table(INSTALLATIONS_TABLE)
        .select(_INSTALLATION_COLUMNS)
        .eq("tenant_id", tenant_id)
        .eq("installation_id", int(installation_id))
        .execute()
    )
    rows = resp.data or []
    return rows[0] if rows else None


def find_installations_by_github_id(
    sb: Any, installation_id: int
) -> list[dict[str, Any]]:
    """Lookup all tenant bindings for a GitHub ``installation_id`` (webhooks)."""
    resp = (
        sb.table(INSTALLATIONS_TABLE)
        .select(_INSTALLATION_COLUMNS)
        .eq("installation_id", int(installation_id))
        .execute()
    )
    return list(resp.data or [])


def upsert_installation(
    sb: Any,
    tenant_id: str,
    *,
    installation_id: int,
    account_id: int,
    account_login: str,
    account_type: str,
    repository_selection: str = "selected",
    permissions: dict[str, Any] | None = None,
    user_tokens: dict[str, Any] | None = None,
    user_token_expires_at: str | None = None,
    status: str = "active",
) -> dict[str, Any]:
    existing = get_installation(sb, tenant_id, installation_id)
    now_iso = datetime.now(UTC).isoformat()
    payload: dict[str, Any] = {
        "github_account_id": int(account_id),
        "github_account_login": account_login,
        "github_account_type": account_type,
        "repository_selection": repository_selection or "selected",
        "permissions": permissions or {},
        "status": status,
        "updated_at": now_iso,
    }
    if user_tokens:
        payload["encrypted_user_tokens"] = encrypt_secrets(user_tokens)
    if user_token_expires_at:
        payload["user_token_expires_at"] = user_token_expires_at

    if existing:
        resp = (
            sb.table(INSTALLATIONS_TABLE)
            .update(payload)
            .eq("tenant_id", tenant_id)
            .eq("installation_id", int(installation_id))
            .execute()
        )
        rows = resp.data or []
        return rows[0] if rows else existing

    insert_data = {
        "tenant_id": tenant_id,
        "installation_id": int(installation_id),
        "created_at": now_iso,
        **payload,
    }
    resp = sb.table(INSTALLATIONS_TABLE).insert(insert_data).execute()
    rows = resp.data or []
    if not rows:
        raise RuntimeError("GitHub App installation insert returned no row")
    return rows[0]


def update_installation_status(
    sb: Any,
    installation_id: int,
    *,
    status: str | None = None,
    repository_selection: str | None = None,
    permissions: dict[str, Any] | None = None,
) -> None:
    payload: dict[str, Any] = {"updated_at": datetime.now(UTC).isoformat()}
    if status is not None:
        payload["status"] = status
    if repository_selection is not None:
        payload["repository_selection"] = repository_selection
    if permissions is not None:
        payload["permissions"] = permissions
    (
        sb.table(INSTALLATIONS_TABLE)
        .update(payload)
        .eq("installation_id", int(installation_id))
        .execute()
    )


def delete_installation_for_all_tenants(sb: Any, installation_id: int) -> None:
    (
        sb.table(REPOS_TABLE)
        .delete()
        .eq("installation_id", int(installation_id))
        .execute()
    )
    (
        sb.table(INSTALLATIONS_TABLE)
        .delete()
        .eq("installation_id", int(installation_id))
        .execute()
    )


def list_repos(sb: Any, tenant_id: str) -> list[dict[str, Any]]:
    resp = (
        sb.table(REPOS_TABLE)
        .select(_REPO_COLUMNS)
        .eq("tenant_id", tenant_id)
        .order("updated_at", desc=True)
        .execute()
    )
    return list(resp.data or [])


def get_repo(sb: Any, tenant_id: str, repo_full_name: str) -> dict[str, Any] | None:
    resp = (
        sb.table(REPOS_TABLE)
        .select(_REPO_COLUMNS)
        .eq("tenant_id", tenant_id)
        .eq("repo_full_name", repo_full_name)
        .execute()
    )
    rows = resp.data or []
    return rows[0] if rows else None


def find_repos_by_installation_and_name(
    sb: Any, installation_id: int, repo_full_name: str
) -> list[dict[str, Any]]:
    resp = (
        sb.table(REPOS_TABLE)
        .select(_REPO_COLUMNS)
        .eq("installation_id", int(installation_id))
        .eq("repo_full_name", repo_full_name)
        .execute()
    )
    return list(resp.data or [])


def upsert_repo(
    sb: Any,
    tenant_id: str,
    *,
    installation_id: int,
    github_repo_id: int,
    repo_full_name: str,
    default_branch: str = "main",
    is_private: bool = True,
    auto_sync_on_push: bool | None = None,
    index_status: str | None = None,
    last_indexed_sha: str | None = None,
    last_indexed_at: str | None = None,
    last_error: str | None = None,
    dependencies_snapshot: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    existing = get_repo(sb, tenant_id, repo_full_name)
    now_iso = datetime.now(UTC).isoformat()
    payload: dict[str, Any] = {
        "installation_id": int(installation_id),
        "github_repo_id": int(github_repo_id),
        "default_branch": default_branch or "main",
        "is_private": bool(is_private),
        "updated_at": now_iso,
    }
    if auto_sync_on_push is not None:
        payload["auto_sync_on_push"] = bool(auto_sync_on_push)
    if index_status is not None:
        payload["index_status"] = index_status
    if last_indexed_sha is not None:
        payload["last_indexed_sha"] = last_indexed_sha
    if last_indexed_at is not None:
        payload["last_indexed_at"] = last_indexed_at
    if last_error is not None:
        payload["last_error"] = last_error
    if dependencies_snapshot is not None:
        payload["dependencies_snapshot"] = dependencies_snapshot

    if existing:
        resp = (
            sb.table(REPOS_TABLE)
            .update(payload)
            .eq("tenant_id", tenant_id)
            .eq("repo_full_name", repo_full_name)
            .execute()
        )
        rows = resp.data or []
        return rows[0] if rows else existing

    insert_data = {
        "tenant_id": tenant_id,
        "repo_full_name": repo_full_name,
        "auto_sync_on_push": True if auto_sync_on_push is None else bool(auto_sync_on_push),
        "index_status": index_status or "connected",
        "dependencies_snapshot": dependencies_snapshot or [],
        "created_at": now_iso,
        **payload,
    }
    resp = sb.table(REPOS_TABLE).insert(insert_data).execute()
    rows = resp.data or []
    if not rows:
        raise RuntimeError("GitHub App repo insert returned no row")
    return rows[0]


def update_repo_index_status(
    sb: Any,
    tenant_id: str,
    repo_full_name: str,
    *,
    index_status: str,
    last_indexed_sha: str | None = None,
    last_indexed_at: str | None = None,
    last_error: str | None = None,
    dependencies_snapshot: list[dict[str, Any]] | None = None,
) -> dict[str, Any] | None:
    """Partially update sync/index fields without overwriting repo metadata."""
    payload: dict[str, Any] = {
        "index_status": index_status,
        "updated_at": datetime.now(UTC).isoformat(),
    }
    if last_indexed_sha is not None:
        payload["last_indexed_sha"] = last_indexed_sha
    if last_indexed_at is not None:
        payload["last_indexed_at"] = last_indexed_at
    if last_error is not None:
        payload["last_error"] = last_error
    if dependencies_snapshot is not None:
        payload["dependencies_snapshot"] = dependencies_snapshot
    resp = (
        sb.table(REPOS_TABLE)
        .update(payload)
        .eq("tenant_id", tenant_id)
        .eq("repo_full_name", repo_full_name)
        .execute()
    )
    rows = resp.data or []
    return rows[0] if rows else None


def delete_repo(sb: Any, tenant_id: str, repo_full_name: str) -> bool:
    resp = (
        sb.table(REPOS_TABLE)
        .delete()
        .eq("tenant_id", tenant_id)
        .eq("repo_full_name", repo_full_name)
        .execute()
    )
    return bool(resp.data)


def delete_tenant_github_app_data(sb: Any, tenant_id: str) -> None:
    """GDPR erasure helper: remove all GitHub App rows for ``tenant_id``."""
    try:
        sb.table(REPOS_TABLE).delete().eq("tenant_id", tenant_id).execute()
        sb.table(INSTALLATIONS_TABLE).delete().eq("tenant_id", tenant_id).execute()
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.error("Failed to delete GitHub App rows for tenant %s: %s", tenant_id, exc)
