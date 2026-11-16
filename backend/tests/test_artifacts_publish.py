"""Tests for the published-artifact endpoints (backend/routes/artifacts.py).

Mirrors test_api_gateway.py's dependency_overrides approach and the
FakeRedis approach from test_chat_activity_persistence.py: the route
module's ``_get_store`` seam is patched to return an in-memory fake,
so no live Redis is needed.
"""

from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.api_gateway import app, get_tenant_id, verify_infrastructure_access
from backend.routes.artifacts import PUBLIC_PAGE_CSP

OWNER_TENANT = "owner-tenant"
OTHER_TENANT = "other-tenant"

# Mutable so individual tests can act as a different tenant (or the
# guest identity) while the autouse override stays installed.
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
    """In-memory stand-in for the gateway Redis pool (get/set/delete)."""

    def __init__(self):
        self.data: dict[str, str] = {}

    async def get(self, key):
        return self.data.get(key)

    async def set(self, key, value):
        self.data[key] = value

    async def delete(self, key):
        return 1 if self.data.pop(key, None) is not None else 0


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


def _publish(client, **overrides):
    payload = {
        "title": "Hello artifact",
        "file_name": "hello.py",
        "language": "python",
        "code": "version = 1",
        "kind": "code",
    }
    payload.update(overrides)
    return client.post("/api/artifacts/publish", json=payload)


def test_publish_returns_id_and_url_and_page_serves(client):
    response = _publish(client)
    assert response.status_code == 200
    data = response.json()
    assert data["id"]
    assert len(data["id"]) >= 16
    assert data["url"].endswith(f"/a/{data['id']}")

    page = client.get(data["url"])
    assert page.status_code == 200
    assert "text/html" in page.headers["content-type"]
    assert "version = 1" in page.text


def test_public_page_has_banner_escaped_title_and_sandbox(client):
    response = _publish(client, title='<script>alert("x")</script>')
    assert response.status_code == 200

    page = client.get(response.json()["url"])
    assert page.status_code == 200
    assert "Content is user-generated and unverified" in page.text
    assert 'sandbox="allow-scripts"' in page.text
    # Title is HTML-escaped in the banner, never raw markup.
    assert "&lt;script&gt;alert(" in page.text
    assert '<script>alert("x")</script>' not in page.text
    # File name shows in the banner meta line.
    assert "hello.py" in page.text
    # Security headers on the public page.
    assert page.headers["x-content-type-options"] == "nosniff"
    assert page.headers["referrer-policy"] == "no-referrer"
    assert "script-src" in page.headers["content-security-policy"]
    assert page.headers["content-security-policy"] == PUBLIC_PAGE_CSP


def test_unknown_artifact_page_is_404(client):
    response = client.get("/a/does-not-exist")
    assert response.status_code == 404


def test_guest_publish_is_401(client):
    _current_tenant["tenant_id"] = "local_guest"
    response = _publish(client)
    assert response.status_code == 401


def test_oversize_code_is_rejected(client):
    response = _publish(client, code="x" * 200_001)
    assert response.status_code == 413


def test_delete_by_non_owner_is_404_and_page_still_serves(client):
    artifact_id = _publish(client).json()["id"]

    _current_tenant["tenant_id"] = OTHER_TENANT
    response = client.delete(f"/api/artifacts/{artifact_id}")
    assert response.status_code == 404

    page = client.get(f"/a/{artifact_id}")
    assert page.status_code == 200


def test_delete_by_owner_removes_page(client):
    artifact_id = _publish(client).json()["id"]

    response = client.delete(f"/api/artifacts/{artifact_id}")
    assert response.status_code == 200
    assert response.json() == {"deleted": True}

    page = client.get(f"/a/{artifact_id}")
    assert page.status_code == 404


def test_publish_with_owned_id_updates_in_place(client):
    artifact_id = _publish(client, code="version = 1").json()["id"]

    response = _publish(client, id=artifact_id, code="version = 2")
    assert response.status_code == 200
    assert response.json()["id"] == artifact_id

    page = client.get(f"/a/{artifact_id}")
    assert page.status_code == 200
    assert "version = 2" in page.text
    assert "version = 1" not in page.text


def test_publish_with_foreign_id_is_404(client):
    artifact_id = _publish(client, code="version = 1").json()["id"]

    _current_tenant["tenant_id"] = OTHER_TENANT
    response = _publish(client, id=artifact_id, code="version = 2")
    assert response.status_code == 404

    # The original artifact is untouched.
    page = client.get(f"/a/{artifact_id}")
    assert page.status_code == 200
    assert "version = 1" in page.text
