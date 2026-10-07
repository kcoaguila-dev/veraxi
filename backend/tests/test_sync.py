"""Tests for the /api/sync/byod endpoints.

The sync routes capture ``get_supabase`` in a closure at app-startup time
(via ``register_sync_routes``).  Patching ``api_gateway._get_supabase``
after the fact has no effect because the closure already holds the original
reference.

Correct targets:
  - ``backend.routes.sync._require_supabase``  — guards the client
  - ``backend.routes.sync._require_premium``   — guards subscription
"""

from http import HTTPStatus
from unittest.mock import MagicMock, patch

import pytest
from backend.api_gateway import app, get_tenant_id
from fastapi.testclient import TestClient

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _clear_dependency_overrides():
    """Ensure dependency overrides are reset after every test."""
    yield
    app.dependency_overrides.clear()


@pytest.fixture()
def client() -> TestClient:
    """TestClient with auth short-circuited to a fixed tenant."""
    app.dependency_overrides[get_tenant_id] = lambda: "test-tenant"
    return TestClient(app, raise_server_exceptions=False)


def _mock_supabase(is_subscribed: bool = True) -> MagicMock:
    """Return a Supabase mock wired for the premium-check query."""
    sb = MagicMock()
    (
        sb.table.return_value
        .select.return_value
        .eq.return_value
        .execute.return_value
    ) = MagicMock(data=[{"is_subscribed": is_subscribed}])
    return sb


# ---------------------------------------------------------------------------
# PUT /api/sync/byod
# ---------------------------------------------------------------------------


class TestPutByod:
    """Push (encrypt + upload) endpoint."""

    def test_503_when_supabase_unavailable(self, client):
        """Regression: used to crash with AttributeError → 500.

        Patching _require_supabase directly because the function reference
        is captured in the route closure at app-startup time.
        """
        from fastapi import HTTPException

        payload = {"encrypted_blob": "abc123", "salt": "seasalt"}
        with patch(
            "backend.routes.sync._require_supabase",
            side_effect=HTTPException(status_code=503, detail="unavailable"),
        ):
            resp = client.put("/api/sync/byod", json=payload)

        assert resp.status_code == HTTPStatus.SERVICE_UNAVAILABLE, (
            "Expected 503 when Supabase is unavailable, "
            f"got {resp.status_code}. This is the bug that caused the "
            "CORS / 500 error in production."
        )

    def test_403_for_non_premium_user(self, client):
        """Non-subscribed users must be rejected before any data is written."""
        from fastapi import HTTPException

        payload = {"encrypted_blob": "abc123", "salt": "seasalt"}
        sb = _mock_supabase()
        with (
            patch("backend.routes.sync._require_supabase", return_value=sb),
            patch(
                "backend.routes.sync._require_premium",
                side_effect=HTTPException(status_code=403, detail="Sync is a premium feature."),
            ),
        ):
            resp = client.put("/api/sync/byod", json=payload)

        assert resp.status_code == HTTPStatus.FORBIDDEN
        assert "premium" in resp.json()["detail"].lower()

    def test_200_for_premium_user(self, client):
        """Premium user with valid payload must receive success."""
        payload = {"encrypted_blob": "abc123", "salt": "seasalt"}
        sb = _mock_supabase(is_subscribed=True)
        sb.table.return_value.upsert.return_value.execute.return_value = MagicMock()

        with (
            patch("backend.routes.sync._require_supabase", return_value=sb),
            patch("backend.routes.sync._require_premium"),  # no-op = premium OK
        ):
            resp = client.put("/api/sync/byod", json=payload)

        assert resp.status_code == HTTPStatus.OK
        assert resp.json() == {"status": "success"}

    def test_422_for_missing_fields(self, client):
        """Pydantic must reject bodies missing the 'salt' field."""
        sb = _mock_supabase()
        with (
            patch("backend.routes.sync._require_supabase", return_value=sb),
            patch("backend.routes.sync._require_premium"),
        ):
            resp = client.put("/api/sync/byod", json={"encrypted_blob": "only-blob"})

        assert resp.status_code == HTTPStatus.UNPROCESSABLE_ENTITY


# ---------------------------------------------------------------------------
# GET /api/sync/byod
# ---------------------------------------------------------------------------


class TestGetByod:
    """Pull (download + decrypt) endpoint."""

    def test_503_when_supabase_unavailable(self, client):
        from fastapi import HTTPException

        with patch(
            "backend.routes.sync._require_supabase",
            side_effect=HTTPException(status_code=503, detail="unavailable"),
        ):
            resp = client.get("/api/sync/byod")

        assert resp.status_code == HTTPStatus.SERVICE_UNAVAILABLE

    def test_403_for_non_premium_user(self, client):
        from fastapi import HTTPException

        sb = _mock_supabase()
        with (
            patch("backend.routes.sync._require_supabase", return_value=sb),
            patch(
                "backend.routes.sync._require_premium",
                side_effect=HTTPException(status_code=403, detail="Sync is a premium feature."),
            ),
        ):
            resp = client.get("/api/sync/byod")

        assert resp.status_code == HTTPStatus.FORBIDDEN

    def test_404_when_no_sync_data_stored(self, client):
        """Premium user who has never pushed gets 404."""
        sb = _mock_supabase()
        # user_sync_data query returns empty list
        sb.table.return_value.select.return_value.eq.return_value.execute.return_value = (
            MagicMock(data=[])
        )

        with (
            patch("backend.routes.sync._require_supabase", return_value=sb),
            patch("backend.routes.sync._require_premium"),
        ):
            resp = client.get("/api/sync/byod")

        assert resp.status_code == HTTPStatus.NOT_FOUND

    def test_200_returns_blob_and_salt(self, client):
        """Premium user with stored data receives encrypted blob + salt."""
        sb = _mock_supabase()
        sb.table.return_value.select.return_value.eq.return_value.execute.return_value = (
            MagicMock(data=[{"encrypted_blob": "enc", "salt": "slt"}])
        )

        with (
            patch("backend.routes.sync._require_supabase", return_value=sb),
            patch("backend.routes.sync._require_premium"),
        ):
            resp = client.get("/api/sync/byod")

        assert resp.status_code == HTTPStatus.OK
        assert resp.json() == {"encrypted_blob": "enc", "salt": "slt"}
