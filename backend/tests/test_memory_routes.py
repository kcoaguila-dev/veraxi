"""Route tests for /api/v1/memories/* with a mocked Supabase client."""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.routes import memories as memory_routes
from backend.routes import usage as usage_routes
from test_sandbox_manager import FakeSupabase


@pytest.fixture()
def harness():
    fake = FakeSupabase()
    app = FastAPI()
    memory_routes.register_memory_routes(app, lambda: "tenant-1", lambda: fake)
    usage_routes.register_usage_routes(app, lambda: "tenant-1", lambda: fake)
    return TestClient(app, raise_server_exceptions=False), fake


@pytest.fixture()
def no_supabase_client():
    app = FastAPI()
    memory_routes.register_memory_routes(app, lambda: "tenant-1", lambda: None)
    return TestClient(app, raise_server_exceptions=False)


class TestMemoryRoutes:
    def test_crud_round_trip(self, harness):
        tc, _fake = harness
        resp = tc.post("/api/v1/memories", json={"content": "Likes dark mode"})
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["content"] == "Likes dark mode"
        assert body["source"] == "manual"
        assert body["user_id"] == "tenant-1"
        assert body["is_valid"] is True
        memory_id = body["id"]

        resp = tc.get("/api/v1/memories")
        assert resp.status_code == 200
        assert [m["id"] for m in resp.json()["memories"]] == [memory_id]

        resp = tc.get(f"/api/v1/memories/{memory_id}")
        assert resp.status_code == 200

        resp = tc.put(
            f"/api/v1/memories/{memory_id}", json={"content": "Likes light mode"}
        )
        assert resp.status_code == 200
        assert resp.json()["content"] == "Likes light mode"

        resp = tc.post(f"/api/v1/memories/{memory_id}/expire")
        assert resp.status_code == 200
        assert resp.json()["is_valid"] is False
        assert resp.json()["valid_to"] is not None

        resp = tc.get("/api/v1/memories?include_expired=false")
        assert resp.json()["memories"] == []
        resp = tc.get("/api/v1/memories")
        assert len(resp.json()["memories"]) == 1  # soft-expired row kept

        resp = tc.delete(f"/api/v1/memories/{memory_id}")
        assert resp.status_code == 200
        assert resp.json()["status"] == "deleted"
        resp = tc.get(f"/api/v1/memories/{memory_id}")
        assert resp.status_code == 404

    def test_create_validation_400(self, harness):
        tc, _fake = harness
        resp = tc.post("/api/v1/memories", json={"content": "  "})
        assert resp.status_code == 400
        resp = tc.post(
            "/api/v1/memories", json={"content": "x", "source": "dream"}
        )
        assert resp.status_code == 400

    def test_unknown_memory_404(self, harness):
        tc, _fake = harness
        assert tc.get("/api/v1/memories/nope").status_code == 404
        assert tc.put("/api/v1/memories/nope", json={"content": "x"}).status_code == 404
        assert tc.post("/api/v1/memories/nope/expire").status_code == 404
        assert tc.delete("/api/v1/memories/nope").status_code == 404

    def test_stateless_mode_501(self, no_supabase_client):
        assert no_supabase_client.get("/api/v1/memories").status_code == 501
        assert (
            no_supabase_client.post(
                "/api/v1/memories", json={"content": "x"}
            ).status_code
            == 501
        )


class TestDeepEstimateRoute:
    def test_estimate_range_from_config(self, harness):
        tc, _fake = harness
        resp = tc.post("/api/chat/estimate-deep", json={})
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["is_estimate"] is True
        assert body["mode"] == "deep"
        assert body["max_rounds"] == 3
        assert body["specialist_agents"] == 3
        assert body["llm_calls"] == {"min": 3, "max": 7}
        assert body["total_tokens"]["min"] < body["total_tokens"]["max"]
        # No pricing is configured by default → cost unknown, not invented.
        assert body["estimated_cost_usd"] is None
