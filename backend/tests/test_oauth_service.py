"""Unit tests for the OAuth service (state, PKCE, exchange, refresh).

Redis and Supabase are in-memory fakes; the provider token exchange is
patched at the service seam so no network is touched.
"""

import base64
import hashlib
import json
import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse

import pytest

from backend.services import integration_store as store
from backend.services import oauth_service


class FakeRedis:
    def __init__(self):
        self.kv: dict[str, str] = {}

    async def get(self, key):
        return self.kv.get(key)

    async def setex(self, key, ttl, value):
        self.kv[key] = value
        return True

    async def set(self, key, value, nx=False, ex=None):
        if nx and key in self.kv:
            return None
        self.kv[key] = value
        return True

    async def delete(self, *keys):
        removed = 0
        for k in keys:
            removed += int(self.kv.pop(k, None) is not None)
        return removed


class _FakeResponse:
    def __init__(self, data):
        self.data = data


class _FakeQuery:
    def __init__(self, table):
        self._table = table
        self._filters = {}
        self._mode = "select"
        self._payload = None

    def select(self, *a, **k):
        return self

    def insert(self, payload):
        self._mode, self._payload = "insert", payload
        return self

    def update(self, payload):
        self._mode, self._payload = "update", payload
        return self

    def delete(self):
        self._mode = "delete"
        return self

    def eq(self, column, value):
        self._filters[column] = value
        return self

    def order(self, *a, **k):
        return self

    def _matches(self, row):
        return all(row.get(k) == v for k, v in self._filters.items())

    def execute(self):
        if self._mode == "insert":
            row = dict(self._payload or {})
            row.setdefault("id", str(uuid.uuid4()))
            row.setdefault("is_enabled", True)
            self._table.rows.append(row)
            return _FakeResponse([row])
        if self._mode == "update":
            updated = []
            for row in self._table.rows:
                if self._matches(row):
                    row.update(self._payload or {})
                    updated.append(row)
            return _FakeResponse(updated)
        if self._mode == "delete":
            self._table.rows = [r for r in self._table.rows if not self._matches(r)]
            return _FakeResponse([])
        return _FakeResponse([r for r in self._table.rows if self._matches(r)])


class _FakeTable:
    def __init__(self):
        self.rows = []

    def select(self, *a, **k):
        return _FakeQuery(self).select(*a, **k)

    def insert(self, payload):
        return _FakeQuery(self).insert(payload)

    def update(self, payload):
        return _FakeQuery(self).update(payload)

    def delete(self):
        return _FakeQuery(self).delete()


class FakeSupabase:
    def __init__(self):
        self._table = _FakeTable()

    def table(self, _name):
        return self._table


@pytest.fixture()
def cfg(monkeypatch):
    monkeypatch.setenv("INTEGRATION_ENCRYPTION_KEY", "oauth-test-key")
    from backend.config import get_config

    get_config.cache_clear()
    yield SimpleNamespace(
        github_client_id="client-id",
        github_client_secret="client-secret",
        oauth_redirect_base_url="https://api.example.com",
        public_app_url="https://app.example.com",
    )
    get_config.cache_clear()


@pytest.mark.asyncio
class TestAuthorizeUrl:
    async def test_url_contains_state_and_pkce(self, cfg):
        redis = FakeRedis()
        url = await oauth_service.build_authorize_url(cfg, redis, "github", "tenant-1")
        params = parse_qs(urlparse(url).query)
        assert params["client_id"] == ["client-id"]
        assert params["code_challenge_method"] == ["S256"]
        state = params["state"][0]
        stored = json.loads(redis.kv[f"oauth:state:{state}"])
        assert stored["tenant_id"] == "tenant-1"
        # PKCE: challenge must be S256(verifier).
        digest = hashlib.sha256(stored["verifier"].encode()).digest()
        expected = base64.urlsafe_b64encode(digest).decode().rstrip("=")
        assert params["code_challenge"] == [expected]

    async def test_unknown_provider_rejected(self, cfg):
        with pytest.raises(ValueError):
            await oauth_service.build_authorize_url(cfg, FakeRedis(), "nope", "t")

    async def test_disabled_provider_rejected(self, cfg):
        with pytest.raises(ValueError):
            await oauth_service.build_authorize_url(cfg, FakeRedis(), "notion", "t")


@pytest.mark.asyncio
class TestCallback:
    async def _start(self, cfg, redis):
        url = await oauth_service.build_authorize_url(cfg, redis, "github", "tenant-1")
        return parse_qs(urlparse(url).query)["state"][0]

    async def test_exchange_and_store(self, cfg, monkeypatch):
        redis = FakeRedis()
        sb = FakeSupabase()
        state = await self._start(cfg, redis)

        async def fake_exchange(config, provider, code, verifier):
            assert code == "auth-code"
            assert verifier  # PKCE verifier from state
            return {"access_token": "tok-1", "scope": "repo,read:user"}

        monkeypatch.setattr(oauth_service, "_exchange_code", fake_exchange)
        row = await oauth_service.handle_callback(cfg, redis, sb, "github", "auth-code", state)
        assert row["provider"] == "github"
        secrets = store.decrypt_row_secrets(row)
        assert secrets["access_token"] == "tok-1"
        assert "tok-1" not in row["encrypted_secrets"]
        # State is single-use.
        assert f"oauth:state:{state}" not in redis.kv

    async def test_invalid_state_rejected(self, cfg, monkeypatch):
        async def fake_exchange(*a, **k):  # pragma: no cover - must not run
            raise AssertionError("exchange must not run on bad state")

        monkeypatch.setattr(oauth_service, "_exchange_code", fake_exchange)
        with pytest.raises(ValueError):
            await oauth_service.handle_callback(
                cfg, FakeRedis(), FakeSupabase(), "github", "c", "bogus-state"
            )


@pytest.mark.asyncio
class TestRefresh:
    def _seed_row(self, sb, expires_at):
        return store.create_integration(
            sb,
            "tenant-1",
            kind="oauth",
            provider="github",
            slug="github",
            display_name="GitHub",
            secrets={"access_token": "old-tok", "refresh_token": "ref-1"},
            token_expires_at=expires_at,
        )

    async def test_fresh_token_returned_without_refresh(self, cfg):
        sb = FakeSupabase()
        future = (datetime.now(UTC) + timedelta(hours=1)).isoformat()
        self._seed_row(sb, future)
        token = await oauth_service.get_valid_access_token(
            cfg, sb, "tenant-1", "github", FakeRedis()
        )
        assert token == "old-tok"

    async def test_expired_token_refreshed_under_lock(self, cfg, monkeypatch):
        sb = FakeSupabase()
        past = (datetime.now(UTC) - timedelta(hours=1)).isoformat()
        self._seed_row(sb, past)

        async def fake_refresh(config, provider, refresh_token):
            assert refresh_token == "ref-1"
            return {"access_token": "new-tok", "expires_in": 3600}

        monkeypatch.setattr(oauth_service, "_refresh_tokens", fake_refresh)
        token = await oauth_service.get_valid_access_token(
            cfg, sb, "tenant-1", "github", FakeRedis()
        )
        assert token == "new-tok"
        row = store.get_integration_by_provider(sb, "tenant-1", "github")
        assert store.decrypt_row_secrets(row)["access_token"] == "new-tok"

    async def test_no_integration_raises(self, cfg):
        with pytest.raises(ValueError):
            await oauth_service.get_valid_access_token(
                cfg, FakeSupabase(), "tenant-1", "github", FakeRedis()
            )
