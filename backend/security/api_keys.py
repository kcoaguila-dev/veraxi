"""
backend/security/api_keys.py

Single-responsibility module for Veraxi personal API key management.

Rules:
- Raw keys are NEVER stored. Only SHA-256 hashes are persisted.
- The raw key is returned exactly once at creation time and then discarded.
- Key format: vx-<32 random hex chars>  (prefix makes them grep-able in config files)
"""
import hashlib
import logging
import secrets

from fastapi import HTTPException
from supabase import Client

logger = logging.getLogger(__name__)

_KEY_PREFIX = "vx-"
_KEY_BYTES = 32  # 256 bits of entropy


def generate_api_key() -> tuple[str, str]:
    """Generate a new API key.

    Returns:
        (raw_key, key_hash) — the raw key must be shown to the user once and
        then discarded. Only key_hash should be stored.
    """
    token = secrets.token_hex(_KEY_BYTES)
    raw_key = f"{_KEY_PREFIX}{token}"
    key_hash = _hash_key(raw_key)
    return raw_key, key_hash


def resolve_api_key(raw_key: str, supabase: Client) -> str:
    """Look up a raw API key in the database and return the tenant_id.

    Args:
        raw_key: The raw key from the Authorization header.
        supabase: An authenticated Supabase service-role client.

    Returns:
        The tenant_id string for the matched key.

    Raises:
        HTTPException(401): If the key is unknown, inactive, or expired.
    """
    key_hash = _hash_key(raw_key)
    tenant_id = _lookup_hash(key_hash, supabase)
    _record_last_used(key_hash, supabase)
    return tenant_id


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

def _hash_key(raw_key: str) -> str:
    """Return the hex SHA-256 digest of a raw key string."""
    return hashlib.sha256(raw_key.encode()).hexdigest()


def _lookup_hash(key_hash: str, supabase: Client) -> str:
    """Query Supabase for an active, non-expired key by hash.

    Returns tenant_id or raises 401.
    """
    try:
        response = (
            supabase
            .table("api_keys")
            .select("tenant_id, expires_at")
            .eq("key_hash", key_hash)
            .eq("is_active", True)
            .single()
            .execute()
        )
    except Exception as e:  # noqa: BLE001
        # Supabase raises when no row is found
        logger.warning(f"API key lookup failed: {e}")
        raise HTTPException(status_code=401, detail="Invalid or revoked API key")

    row = response.data
    if not row:
        raise HTTPException(status_code=401, detail="Invalid or revoked API key")

    _check_expiry(row.get("expires_at"))
    return row["tenant_id"]


def _check_expiry(expires_at: str | None) -> None:
    """Raise 401 if the key has passed its expiry date."""
    if not expires_at:
        return  # permanent key

    from datetime import datetime, timezone
    expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    if datetime.now(timezone.utc) > expiry:
        raise HTTPException(status_code=401, detail="API key has expired")


def _record_last_used(key_hash: str, supabase: Client) -> None:
    """Fire-and-forget update of last_used_at. Failures are logged, not raised."""
    try:
        from datetime import datetime, timezone
        supabase.table("api_keys").update(
            {"last_used_at": datetime.now(timezone.utc).isoformat()}
        ).eq("key_hash", key_hash).execute()
    except Exception as e:  # noqa: BLE001
        logger.warning(f"Failed to update last_used_at for API key: {e}")
