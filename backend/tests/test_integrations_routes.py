"""Route tests for /api/integrations with a mocked Supabase client.

The fake implements just the chainable query-builder surface the
integration store uses (select/eq/order/insert/update/delete/execute).
No real database or network is touched; the MCP handshake probe is
patched at the routes seam.
"""

import uuid

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.routes import integrations as integrations_routes
from backend.security.token_vault import decrypt_secrets


class _FakeResponse:
    def __init__(self, data):
        self.data = data


class _FakeQuery:
    def __init__(self, table):
        self._table = table
        self._filters: dict = {}
        self._mode = "select"
        self._payload: dict | None = None

    def select(self, *_a, **_k):
        self._mode = "select"
        return self

    def insert(self, payload):
        self._mode = "insert"
        self._payload = payload
        return self

    def update(self, payload):
        self._mode = "update"
        self._payload = payload
        return self

    def delete(self):
        self._mode = "delete"
        return self

    def eq(self, column, value):
        self._filters[column] = value
        return self

    def order(self, *_a, **_k):
        return self

    def _matches(self, row):
        return all(row.get(k) == v for k, v in self._filters.items())

    def execute(self):
        if self._mode == "insert":
            row = dict(self._payload or {})
            row.setdefault("id", str(uuid.uuid4()))
            row.setdefault("created_at", "2026-01-01T00:00:00Z")
            row.setdefault("updated_at", "2026-01-01T00:00:00Z")
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
            kept, removed = [], []
            for row in self._table.rows:
                (removed if self._matches(row) else kept).append(row)
            self._table.rows = kept
            return _FakeResponse(removed)
        return _FakeResponse([r for r in self._table.rows if self._matches(r)])


class _FakeTable:
    def __init__(self):
        self.rows: list[dict] = []

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
def client(monkeypatch):
    monkeypatch.setenv("INTEGRATION_ENCRYPTION_KEY", "route-test-key")
    from backend.config import get_config

    get_config.cache_clear()

    fake = FakeSupabase()
    app = FastAPI()

    async def fake_probe(url, headers, transport):
        return ["search", "fetch"]

    monkeypatch.setattr(integrations_routes, "_probe_mcp_server", fake_probe)
    monkeypatch.setattr(
        integrations_routes, "validate_external_url", lambda url, **k: url
    )
    integrations_routes.register_integration_routes(
        app, lambda: "tenant-1", lambda: fake, None
    )
    yield TestClient(app), fake
    get_config.cache_clear()


def _create(client):
    tc, _fake = client
    resp = tc.post(
        "/api/integrations/mcp",
        json={
            "display_name": "My Server",
            "url": "https://mcp.example.com/mcp",
            "transport": "auto",
            "headers": {"Authorization": "Bearer secret-token"},
        },
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


class TestCreateAndList:
    def test_create_masks_secrets(self, client):
        body = _create(client)
        assert body["slug"] == "my-server"
        assert body["has_auth"] is True
        assert "encrypted_secrets" not in body
        assert "secret-token" not in str(body)
        assert body["config"]["tool_names"] == ["search", "fetch"]

    def test_secrets_stored_encrypted(self, client):
        _tc, fake = client
        _create(client)
        row = fake._table.rows[0]
        assert row["encrypted_secrets"]
        assert "secret-token" not in row["encrypted_secrets"]
        assert decrypt_secrets(row["encrypted_secrets"]) == {
            "headers": {"Authorization": "Bearer secret-token"}
        }

    def test_list_masks_secrets(self, client):
        tc, _fake = client
        _create(client)
        resp = tc.get("/api/integrations")
        assert resp.status_code == 200
        items = resp.json()["integrations"]
        assert len(items) == 1
        assert items[0]["has_auth"] is True
        assert "encrypted_secrets" not in items[0]
        assert "secret-token" not in resp.text

    def test_slug_uniqueness(self, client):
        tc, _fake = client
        first = _create(client)
        resp = tc.post(
            "/api/integrations/mcp",
            json={"display_name": "My Server", "url": "https://other.example.com/mcp"},
        )
        assert resp.status_code == 201
        assert resp.json()["slug"] != first["slug"]
        assert resp.json()["slug"] == "my-server-2"


class TestPatchDeleteTest:
    def test_patch_toggle_and_rename(self, client):
        tc, _fake = client
        created = _create(client)
        resp = tc.patch(
            f"/api/integrations/{created['id']}",
            json={"is_enabled": False, "display_name": "Renamed"},
        )
        assert resp.status_code == 200
        assert resp.json()["is_enabled"] is False
        assert resp.json()["display_name"] == "Renamed"

    def test_patch_missing_returns_404(self, client):
        tc, _fake = client
        resp = tc.patch("/api/integrations/nope", json={"is_enabled": False})
        assert resp.status_code == 404

    def test_delete(self, client):
        tc, fake = client
        created = _create(client)
        resp = tc.delete(f"/api/integrations/{created['id']}")
        assert resp.status_code == 200
        assert fake._table.rows == []

    def test_test_endpoint_returns_tools(self, client):
        tc, _fake = client
        created = _create(client)
        resp = tc.post(f"/api/integrations/{created['id']}/test")
        assert resp.status_code == 200
        body = resp.json()
        assert body["tools"] == ["search", "fetch"]
        assert body["tool_count"] == 2
        assert body["status"] == "connected"


class TestNoSupabase:
    def test_501_without_supabase(self, monkeypatch):
        app = FastAPI()
        integrations_routes.register_integration_routes(
            app, lambda: "tenant-1", lambda: None, None
        )
        tc = TestClient(app, raise_server_exceptions=False)
        resp = tc.get("/api/integrations")
        assert resp.status_code == 501
