"""Tests for modular billing endpoints and self-hosted mode behavior."""

from http import HTTPStatus
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.api_gateway import app, get_tenant_id
from backend.routes.sync import _require_premium


@pytest.fixture(autouse=True)
def _clear_dependency_overrides():
    yield
    app.dependency_overrides.clear()


@pytest.fixture
def client() -> TestClient:
    app.dependency_overrides[get_tenant_id] = lambda: "test-tenant"
    return TestClient(app, raise_server_exceptions=False)


def test_checkout_disabled_in_self_hosted_mode(client):
    """When is_enterprise is False or STRIPE_API_KEY is unset, checkout returns 501."""
    mock_cfg = MagicMock(is_enterprise=False, stripe_api_key="")
    with patch("backend.routes.payments.get_config", return_value=mock_cfg):
        resp = client.post(
            "/v1/payments/create-checkout-session",
            json={"plan": "monthly"},
        )
    assert resp.status_code == HTTPStatus.NOT_IMPLEMENTED
    assert "disabled" in resp.json()["detail"].lower()


def test_webhook_disabled_in_self_hosted_mode(client):
    """When is_enterprise is False, stripe webhook returns 501."""
    mock_cfg = MagicMock(is_enterprise=False, stripe_api_key="")
    with patch("backend.routes.payments.get_config", return_value=mock_cfg):
        resp = client.post(
            "/admin/stripe-webhook",
            headers={"stripe-signature": "test-sig"},
            content=b"{}",
        )
    assert resp.status_code == HTTPStatus.NOT_IMPLEMENTED
    assert "disabled" in resp.json()["detail"].lower()


def test_sync_require_premium_bypassed_when_not_enterprise():
    """In self-hosted mode (is_enterprise=False), sync does not query Supabase or raise 403."""
    sb = MagicMock()
    # Should not raise exception
    _require_premium(sb, "tenant-self-hosted", is_enterprise=False)
    # Supabase table should never have been touched
    sb.table.assert_not_called()


def test_sync_require_premium_enforced_when_enterprise():
    """In enterprise mode (is_enterprise=True), sync queries Supabase and raises 403 if not subscribed."""
    from fastapi import HTTPException

    sb = MagicMock()
    sb.table.return_value.select.return_value.eq.return_value.execute.return_value = (
        MagicMock(data=[{"is_subscribed": False}])
    )

    with pytest.raises(HTTPException) as exc_info:
        _require_premium(sb, "tenant-enterprise-unpaid", is_enterprise=True)

    assert exc_info.value.status_code == HTTPStatus.FORBIDDEN
    assert "premium" in str(exc_info.value.detail).lower()
