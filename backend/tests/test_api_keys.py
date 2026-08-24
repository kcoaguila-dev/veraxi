"""
backend/tests/test_api_keys.py

Unit tests for the API key security module.
No real Supabase connection needed — uses mocks.
"""
import hashlib
from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException

from backend.security.api_keys import (
    generate_api_key,
    resolve_api_key,
    _hash_key,
    _KEY_PREFIX,
)


# ---------------------------------------------------------------------------
# generate_api_key
# ---------------------------------------------------------------------------

class TestGenerateApiKey:
    def test_raw_key_starts_with_prefix(self):
        raw_key, _ = generate_api_key()
        assert raw_key.startswith(_KEY_PREFIX)

    def test_raw_key_and_hash_are_different(self):
        raw_key, key_hash = generate_api_key()
        assert raw_key != key_hash

    def test_hash_is_sha256_of_raw_key(self):
        raw_key, key_hash = generate_api_key()
        expected = hashlib.sha256(raw_key.encode()).hexdigest()
        assert key_hash == expected

    def test_each_call_produces_unique_key(self):
        key1, _ = generate_api_key()
        key2, _ = generate_api_key()
        assert key1 != key2


# ---------------------------------------------------------------------------
# _hash_key
# ---------------------------------------------------------------------------

class TestHashKey:
    def test_deterministic(self):
        assert _hash_key("vx-abc") == _hash_key("vx-abc")

    def test_different_inputs_differ(self):
        assert _hash_key("vx-abc") != _hash_key("vx-xyz")


# ---------------------------------------------------------------------------
# resolve_api_key
# ---------------------------------------------------------------------------

def _make_supabase_mock(row: dict | None):
    """Return a Supabase client mock that yields the given row (or None)."""
    mock = MagicMock()
    chain = mock.table.return_value.select.return_value.eq.return_value.eq.return_value.single.return_value.execute.return_value
    if row is None:
        mock.table.return_value.select.return_value.eq.return_value.eq.return_value.single.return_value.execute.side_effect = Exception("No rows found")
    else:
        chain.data = row
    return mock


class TestResolveApiKey:
    def test_valid_key_returns_tenant_id(self):
        raw_key, _ = generate_api_key()
        supabase = _make_supabase_mock({"tenant_id": "user-123", "expires_at": None})
        # Patch _record_last_used to avoid a second DB call
        with patch("backend.security.api_keys._record_last_used"):
            tenant_id = resolve_api_key(raw_key, supabase)
        assert tenant_id == "user-123"

    def test_unknown_key_raises_401(self):
        raw_key, _ = generate_api_key()
        supabase = _make_supabase_mock(None)  # DB raises on no row
        with pytest.raises(HTTPException) as exc_info:
            resolve_api_key(raw_key, supabase)
        assert exc_info.value.status_code == 401

    def test_expired_key_raises_401(self):
        raw_key, _ = generate_api_key()
        # expires_at is in the past
        supabase = _make_supabase_mock({
            "tenant_id": "user-456",
            "expires_at": "2000-01-01T00:00:00+00:00",
        })
        with patch("backend.security.api_keys._record_last_used"):
            with pytest.raises(HTTPException) as exc_info:
                resolve_api_key(raw_key, supabase)
        assert exc_info.value.status_code == 401
        assert "expired" in exc_info.value.detail.lower()

    def test_future_expiry_succeeds(self):
        raw_key, _ = generate_api_key()
        supabase = _make_supabase_mock({
            "tenant_id": "user-789",
            "expires_at": "2099-01-01T00:00:00+00:00",
        })
        with patch("backend.security.api_keys._record_last_used"):
            tenant_id = resolve_api_key(raw_key, supabase)
        assert tenant_id == "user-789"
