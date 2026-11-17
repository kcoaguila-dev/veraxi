"""Tests for the artifact runtime-storage endpoints and the
published-page CSP / sibling bundling (backend/routes/artifacts.py).

Mirrors test_artifacts_work.py: tenant dependency overrides and the
``_get_store`` seam patched to an in-memory FakeRedis (extended
with hdel).
"""

from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.api_gateway import app, get_tenant_id, verify_infrastructure_access
from backend.routes.artifacts import (
    PUBLIC_PAGE_CSP,
    _build_react_document,
    prepare_react_artifact,
)

OWNER_TENANT = "owner-tenant"
OTHER_TENANT = "other-tenant"
SCOPE = "thread-1:0:0"

_current_tenant = {"tenant_id": OWNER_TENANT}


@pytest.fixture(autouse=True)
def override_dependencies():
    _current_tenant["tenant_id"] = OWNER_TENANT

    async def override_get_tenant_id():
        return _current_tenant["tenant_id"]

    async def override_verify_infrastructure_access():
        return _current_tenant["tenant_id"]

    app.dependency_overrides[get_tenant_id] = override_get_tenant_id
    app.dependency_overrides[verify_infrastructure_access] = (
        override_verify_infrastructure_access
    )
    yield
    app.dependency_overrides.clear()


class FakeRedis:
    def __init__(self):
        self.data: dict[str, str] = {}
        self.hashes: dict[str, dict[str, str]] = {}

    async def get(self, key):
        return self.data.get(key)

    async def set(self, key, value):
        self.data[key] = value

    async def delete(self, key):
        return 1 if self.data.pop(key, None) is not None else 0

    async def hset(self, key, field, value):
        self.hashes.setdefault(key, {})[field] = value
        return 1

    async def hgetall(self, key):
        return dict(self.hashes.get(key, {}))

    async def hdel(self, key, field):
        return 1 if self.hashes.get(key, {}).pop(field, None) is not None else 0


@pytest.fixture
def fake_redis():
    return FakeRedis()


@pytest.fixture
def client(fake_redis, monkeypatch):
    monkeypatch.setattr(
        "backend.routes.artifacts._get_store", lambda request: fake_redis
    )
    mock_pool = AsyncMock()
    mock_pool.close = AsyncMock()
    with patch(
        "backend.api_gateway.create_pool", new_callable=AsyncMock
    ) as mock_create_pool:
        mock_create_pool.return_value = mock_pool
        with TestClient(app) as test_client:
            yield test_client


def _put(client, key="k", value="v", scope=SCOPE):
    return client.put(
        f"/api/artifacts/storage/{scope}", json={"key": key, "value": value}
    )


def _get(client, scope=SCOPE):
    return client.get(f"/api/artifacts/storage/{scope}")


def test_put_get_delete_round_trip(client):
    assert _put(client).status_code == 200
    assert _get(client).json() == {"entries": {"k": "v"}}
    response = client.delete(f"/api/artifacts/storage/{SCOPE}/k")
    assert response.status_code == 200
    assert _get(client).json() == {"entries": {}}


def test_scope_id_with_colons_is_captured_fully(client):
    # Draft scopes are "{thread}:{message}:{artifact}" — the route
    # must not truncate at the first colon.
    assert _put(client, scope="t-9:12:3").status_code == 200
    assert _get(client, scope="t-9:12:3").json() == {"entries": {"k": "v"}}
    assert _get(client, scope="t-9").json() == {"entries": {}}


def test_tenant_isolation(client):
    assert _put(client).status_code == 200
    _current_tenant["tenant_id"] = OTHER_TENANT
    assert _get(client).json() == {"entries": {}}


def test_guest_tenant_can_use_storage(client):
    _current_tenant["tenant_id"] = "local_guest"
    assert _put(client).status_code == 200
    assert _get(client).json() == {"entries": {"k": "v"}}


def test_malformed_bodies_are_400(client):
    assert _put(client, key="").status_code == 400
    response = client.put(
        f"/api/artifacts/storage/{SCOPE}", json={"key": "k", "value": 42}
    )
    assert response.status_code == 400
    response = client.put(f"/api/artifacts/storage/{SCOPE}", json=["nope"])
    assert response.status_code == 400


def test_oversize_value_is_413(client):
    assert _put(client, value="x" * 100_001).status_code == 413
    assert _put(client, value="x" * 100_000).status_code == 200


def _seed_scope(fake_redis, entries, scope=SCOPE):
    key = f"tenant:{OWNER_TENANT}:artifact_storage:{scope}"
    fake_redis.hashes[key] = dict(entries)


def test_key_count_cap_is_413(client, fake_redis):
    # Seeded directly: the ingest rate limit makes 100 live PUTs
    # impractical in tests, and the cap logic reads the same hash.
    _seed_scope(fake_redis, {f"k{i}": "v" for i in range(100)})
    assert _put(client, key="one-too-many", value="v").status_code == 413
    # Updating an existing key at the cap is still fine.
    assert _put(client, key="k0", value="v2").status_code == 200


def test_total_scope_cap_is_413(client, fake_redis):
    _seed_scope(fake_redis, {"a": "x" * 1_950_000})
    assert _put(client, key="b", value="x" * 100_000).status_code == 413
    assert _put(client, key="b", value="x" * 50_000).status_code == 200


def test_unpublish_preserves_draft_storage(client):
    # Publish, store draft data, unpublish: the draft scope must
    # survive (storage is keyed separately from the public record).
    publish = client.post(
        "/api/artifacts/publish",
        json={
            "title": "T",
            "file_name": "a.html",
            "language": "html",
            "code": "<p>hi</p>",
            "kind": "html",
        },
    )
    assert publish.status_code == 200
    artifact_id = publish.json()["id"]
    assert _put(client).status_code == 200
    assert client.delete(f"/api/artifacts/{artifact_id}").status_code == 200
    assert _get(client).json() == {"entries": {"k": "v"}}


def test_public_page_csp_allows_blob_module_scripts(client):
    # Phase 3 sibling modules load from Blob URLs on published
    # pages; the srcdoc frame inherits this CSP, so script-src must
    # allow blob: (and nothing else was widened for the mechanism).
    script_src = next(
        part for part in PUBLIC_PAGE_CSP.split(";") if "script-src" in part
    )
    assert "blob:" in script_src
    assert "worker-src" not in PUBLIC_PAGE_CSP

    publish = client.post(
        "/api/artifacts/publish",
        json={
            "title": "T",
            "file_name": "App.tsx",
            "language": "tsx",
            "code": "export default function App() { return <div/>; }",
            "kind": "react",
        },
    )
    artifact_id = publish.json()["id"]
    page = client.get(f"/a/{artifact_id}")
    assert page.status_code == 200
    assert "blob:" in page.headers["content-security-policy"]


def test_python_react_builder_bundles_siblings_like_dart():
    source = (
        "import Helper from './Helper';\n"
        "import './styles.css';\n"
        "export default function App() { return <Helper/>; }\n"
    )
    doc = _build_react_document(
        source,
        sibling_files={
            "Helper.tsx": "export default function Helper() { return <div/>; }",
            "styles.css": ".x { color: red; }",
        },
    )
    # CSS sibling inlined, sibling module shipped, Blob bootstrap used.
    assert ".x { color: red; }" in doc
    assert 'data-spec="./Helper"' in doc
    assert "URL.createObjectURL" in doc
    assert "new Blob" in doc
    # The entry keeps its relative import for the bootstrap rewrite.
    prepared = prepare_react_artifact(source, sibling_files={"Helper.tsx": "x"})
    assert "./Helper" in prepared


def test_python_react_builder_reports_missing_sibling():
    doc = _build_react_document(
        "import Nope from './Nope';\nexport default function App() { return <div/>; }",
        sibling_files={"Other.tsx": "export default function Other() {}"},
    )
    assert "Missing sibling module: ./Nope" in doc
    assert "Preview error" in doc


def test_public_documents_carry_in_memory_storage_shim():
    doc = _build_react_document(
        "export default function App() { return <div/>; }"
    )
    assert "window.veraxiStorage" in doc
