"""Tests for the artifact-work sync endpoints (backend/routes/artifacts.py).

Mirrors test_artifacts_publish.py: dependency_overrides for the
tenant, and the route module's ``_get_store`` seam patched to an
in-memory FakeRedis (extended here with the hash commands the work
endpoints use), so no live Redis is needed.
"""

from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.api_gateway import app, get_tenant_id, verify_infrastructure_access

OWNER_TENANT = "owner-tenant"
OTHER_TENANT = "other-tenant"
THREAD_ID = "thread-1"

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
    """In-memory stand-in for the gateway Redis pool.

    get/set/delete mirror test_artifacts_publish.py's fake; hset /
    hgetall back the artifact-work hash.
    """

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


def _state(**overrides):
    state = {
        "versions": ['print("v1")', 'print("v2")'],
        "versionIndex": 1,
        "originalCode": 'print("v1")',
        "updatedAt": "2026-11-17T00:00:00Z",
    }
    state.update(overrides)
    return state


def _put(client, state=None, message_index=0, artifact_index=0, thread_id=THREAD_ID):
    return client.put(
        f"/api/artifacts/work/{thread_id}",
        json={
            "message_index": message_index,
            "artifact_index": artifact_index,
            "state": _state() if state is None else state,
        },
    )


def _get(client, thread_id=THREAD_ID):
    return client.get(f"/api/artifacts/work/{thread_id}")


def test_put_then_get_round_trips_state_exactly(client):
    state = _state(publishedUrl="https://example.test/a/abc")

    response = _put(client, state=state)
    assert response.status_code == 200
    assert response.json() == {"saved": True}

    response = _get(client)
    assert response.status_code == 200
    # The state comes back exactly as sent, updatedAt included: it is
    # stored opaquely, never required or stripped.
    assert response.json() == {"entries": {"0:0": state}}


def test_two_entries_coexist_in_one_thread(client):
    first = _state()
    second = _state(versions=['print("other")'], versionIndex=0)

    assert _put(client, state=first, message_index=0, artifact_index=0).status_code == 200
    assert _put(client, state=second, message_index=2, artifact_index=1).status_code == 200

    entries = _get(client).json()["entries"]
    assert entries == {"0:0": first, "2:1": second}


def test_second_put_to_same_field_overwrites(client):
    assert _put(client, state=_state()).status_code == 200
    updated = _state(versions=['print("v3")'], versionIndex=0)
    assert _put(client, state=updated).status_code == 200

    assert _get(client).json()["entries"] == {"0:0": updated}


def test_tenant_isolation(client):
    assert _put(client).status_code == 200

    _current_tenant["tenant_id"] = OTHER_TENANT
    response = _get(client)
    assert response.status_code == 200
    assert response.json() == {"entries": {}}


def test_guest_tenant_can_put_and_get(client):
    # Deliberate difference from publish (which rejects local_guest
    # with 401): work sync is private per-tenant data, like chat
    # history, so guests sync their own work too.
    _current_tenant["tenant_id"] = "local_guest"

    response = _put(client)
    assert response.status_code == 200
    assert response.json() == {"saved": True}

    response = _get(client)
    assert response.status_code == 200
    assert response.json()["entries"] == {"0:0": _state()}


def test_versions_not_a_list_of_strings_is_400(client):
    response = _put(client, state=_state(versions="not-a-list"))
    assert response.status_code == 400

    response = _put(client, state=_state(versions=["ok", 42]))
    assert response.status_code == 400

    response = _put(client, state={"versionIndex": 0})
    assert response.status_code == 400


def test_too_many_versions_is_400(client):
    response = _put(client, state=_state(versions=["v"] * 201))
    assert response.status_code == 400


def test_negative_index_is_400(client):
    response = _put(client, message_index=-1)
    assert response.status_code == 400

    response = _put(client, artifact_index=-2)
    assert response.status_code == 400


def test_oversize_state_is_413(client):
    # Each version is exactly at the per-version cap and the count is
    # legal, so only the total serialized-size limit can reject this.
    state = _state(versions=["x" * 200_000] * 6)
    response = _put(client, state=state)
    assert response.status_code == 413


def test_get_unknown_thread_is_empty_entries(client):
    response = _get(client, thread_id="no-such-thread")
    assert response.status_code == 200
    assert response.json() == {"entries": {}}


def test_corrupt_entry_is_skipped_not_fatal(client, fake_redis):
    assert _put(client).status_code == 200
    key = f"tenant:{OWNER_TENANT}:artifact_work:{THREAD_ID}"
    fake_redis.hashes[key]["9:9"] = "{not json"

    response = _get(client)
    assert response.status_code == 200
    assert response.json()["entries"] == {"0:0": _state()}
