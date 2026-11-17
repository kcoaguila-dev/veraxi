"""Tests for the OpenAPI importer (parse, compile, execute, routes).

HTTP execution is patched at the importer seam; Supabase is an
in-memory fake. No network is used (SSRF DNS is mocked where a public
URL must pass validation).
"""

import json
import uuid

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.routes import integrations_openapi
from backend.security import ssrf
from backend.services import integration_store as store
from backend.services import openapi_importer

SPEC = {
    "openapi": "3.0.0",
    "info": {"title": "Widgets API", "version": "1.0"},
    "servers": [{"url": "https://api.example.com/v1"}],
    "paths": {
        "/widgets": {
            "get": {
                "operationId": "listWidgets",
                "summary": "List widgets",
                "parameters": [
                    {"name": "limit", "in": "query", "schema": {"type": "integer"}}
                ],
            },
            "post": {
                "operationId": "createWidget",
                "summary": "Create a widget",
                "requestBody": {
                    "content": {
                        "application/json": {
                            "schema": {
                                "type": "object",
                                "properties": {"name": {"type": "string"}},
                                "required": ["name"],
                            }
                        }
                    }
                },
            },
        },
        "/widgets/{id}": {
            "get": {
                "operationId": "getWidget",
                "parameters": [
                    {"name": "id", "in": "path", "required": True, "schema": {"type": "string"}}
                ],
            }
        },
    },
}
SPEC_TEXT = json.dumps(SPEC)


@pytest.fixture(autouse=True)
def _public_dns(monkeypatch):
    monkeypatch.setattr(ssrf, "_resolve", lambda host: ["93.184.216.34"])
    monkeypatch.setattr(ssrf, "_allow_private", lambda: False)
    monkeypatch.setenv("INTEGRATION_ENCRYPTION_KEY", "openapi-test-key")
    from backend.config import get_config

    get_config.cache_clear()
    yield
    get_config.cache_clear()


class TestParse:
    def test_parse_json(self):
        spec = openapi_importer.parse_spec(SPEC_TEXT)
        assert spec["info"]["title"] == "Widgets API"

    def test_parse_yaml(self):
        yaml_text = "openapi: 3.1.0\ninfo:\n  title: Y\n  version: '2'\npaths: {}\n"
        spec = openapi_importer.parse_spec(yaml_text)
        assert spec["openapi"] == "3.1.0"

    def test_rejects_swagger_2(self):
        with pytest.raises(ValueError):
            openapi_importer.parse_spec(json.dumps({"swagger": "2.0", "paths": {}}))

    def test_rejects_garbage(self):
        with pytest.raises(ValueError):
            openapi_importer.parse_spec("not a spec at all: [")


class TestListAndCompile:
    def test_list_operations(self):
        ops = openapi_importer.list_operations(SPEC)
        ids = {o["operation_id"] for o in ops}
        assert ids == {"listWidgets", "createWidget", "getWidget"}
        get_op = next(o for o in ops if o["operation_id"] == "getWidget")
        assert get_op["method"] == "GET"
        assert get_op["server_url"] == "https://api.example.com/v1"

    def test_compile_selected(self):
        compiled = openapi_importer.compile_operations(SPEC, ["listWidgets", "getWidget"])
        assert len(compiled) == 2
        assert compiled[1]["parameters"][0]["name"] == "id"

    def test_compile_rejects_too_many(self):
        ids = [f"op{i}" for i in range(11)]
        with pytest.raises(ValueError):
            openapi_importer.compile_operations(SPEC, ids)

    def test_compile_rejects_unknown(self):
        with pytest.raises(ValueError):
            openapi_importer.compile_operations(SPEC, ["nope"])

    def test_schema_shape(self):
        compiled = openapi_importer.compile_operations(SPEC, ["getWidget", "createWidget"])
        schema = openapi_importer.operation_to_schema("widgets-api", compiled[0])
        assert schema["function"]["name"] == "api__widgets-api__getWidget"
        assert schema["function"]["parameters"]["required"] == ["id"]
        post_schema = openapi_importer.operation_to_schema("widgets-api", compiled[1])
        assert "requires user confirmation" in post_schema["function"]["description"]
        assert "name" in post_schema["function"]["parameters"]["properties"]


# ---------------------------------------------------------------------------
# Execution against a fake stored integration
# ---------------------------------------------------------------------------


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


def _seed_openapi_integration(sb):
    compiled = openapi_importer.compile_operations(
        SPEC, ["listWidgets", "createWidget", "getWidget"]
    )
    return store.create_integration(
        sb,
        "tenant-1",
        kind="openapi",
        provider="custom_openapi",
        slug="widgets-api",
        display_name="Widgets API",
        config={"operations": compiled, "auth": {"type": "bearer"}},
        secrets={"access_token": "secret-bearer"},
    )


class _HttpResult:
    def __init__(self, text, status_code=200):
        self.text = text
        self.status_code = status_code


@pytest.mark.asyncio
class TestExecution:
    async def test_get_with_path_param_and_auth(self, monkeypatch):
        sb = FakeSupabase()
        _seed_openapi_integration(sb)
        monkeypatch.setattr(openapi_importer, "_default_supabase", lambda: sb)
        seen = {}

        async def fake_http(method, url, **kwargs):
            seen.update(method=method, url=url, kwargs=kwargs)
            return _HttpResult('{"id": "w1"}')

        monkeypatch.setattr(openapi_importer, "_http_request", fake_http)
        out = await openapi_importer.execute_openapi_tool(
            "api__widgets-api__getWidget", {"id": "w1"}, "tenant-1"
        )
        assert out == '{"id": "w1"}'
        assert seen["url"] == "https://api.example.com/v1/widgets/w1"
        assert seen["kwargs"]["headers"]["Authorization"] == "Bearer secret-bearer"

    async def test_response_truncated_at_16kb(self, monkeypatch):
        sb = FakeSupabase()
        _seed_openapi_integration(sb)
        monkeypatch.setattr(openapi_importer, "_default_supabase", lambda: sb)

        async def fake_http(method, url, **kwargs):
            return _HttpResult("x" * 100_000)

        monkeypatch.setattr(openapi_importer, "_http_request", fake_http)
        out = await openapi_importer.execute_openapi_tool(
            "api__widgets-api__listWidgets", {}, "tenant-1"
        )
        assert len(out.encode()) <= openapi_importer.MAX_RESPONSE_BYTES + 64
        assert "truncated" in out

    async def test_non_get_requires_confirmation(self, monkeypatch):
        sb = FakeSupabase()
        _seed_openapi_integration(sb)
        monkeypatch.setattr(openapi_importer, "_default_supabase", lambda: sb)
        assert await openapi_importer.openapi_requires_confirmation(
            "tenant-1", "api__widgets-api__createWidget"
        )
        assert not await openapi_importer.openapi_requires_confirmation(
            "tenant-1", "api__widgets-api__listWidgets"
        )


@pytest.mark.asyncio
class TestDispatchGateForApiTools:
    async def test_unconfirmed_post_blocked(self, monkeypatch):
        from backend.mcp_server import tool_dispatch

        sb = FakeSupabase()
        _seed_openapi_integration(sb)
        monkeypatch.setattr(openapi_importer, "_default_supabase", lambda: sb)

        async def fake_execute(*a, **k):  # pragma: no cover - must not run
            raise AssertionError("unconfirmed POST must not execute")

        monkeypatch.setattr(openapi_importer, "execute_openapi_tool", fake_execute)
        context, merged = await tool_dispatch.execute_tools_internal(
            [{"name": "api__widgets-api__createWidget", "args": {"name": "w"}}],
            "tenant-1",
            {},
        )
        assert "tool_confirmation_required" in context
        assert merged[0].id == "tool_confirmation"


class TestRoutes:
    def _client(self, monkeypatch):
        fake = FakeSupabase()
        app = FastAPI()
        integrations_openapi.register_openapi_routes(
            app, lambda: "tenant-1", lambda: fake, None
        )
        return TestClient(app), fake

    def test_preview(self, monkeypatch):
        tc, _fake = self._client(monkeypatch)
        resp = tc.post(
            "/api/integrations/openapi/preview", json={"spec_text": SPEC_TEXT}
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["title"] == "Widgets API"
        assert len(body["operations"]) == 3

    def test_create_masks_auth(self, monkeypatch):
        tc, fake = self._client(monkeypatch)
        resp = tc.post(
            "/api/integrations/openapi",
            json={
                "spec_text": SPEC_TEXT,
                "selected_operation_ids": ["listWidgets"],
                "auth_type": "bearer",
                "auth_value": "topsecret",
            },
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["has_auth"] is True
        assert "topsecret" not in resp.text
        row = fake._table.rows[0]
        assert store.decrypt_row_secrets(row) == {"access_token": "topsecret"}

    def test_create_rejects_too_many_ops(self, monkeypatch):
        tc, _fake = self._client(monkeypatch)
        resp = tc.post(
            "/api/integrations/openapi",
            json={
                "spec_text": SPEC_TEXT,
                "selected_operation_ids": [f"op{i}" for i in range(11)],
            },
        )
        assert resp.status_code == 400
