"""Route tests for /api/v1/sandboxes/* with a mocked Supabase client."""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from backend.routes import sandboxes as sandbox_routes
from backend.sandbox.manager import SandboxManager
from backend.sandbox.ws_runner_provider import GLOBAL_REGISTRY
from backend.security.token_vault import decrypt_secrets
from backend.services import sandbox_store as store
from test_sandbox_manager import FakeProvider, FakeSupabase


@pytest.fixture()
def harness(monkeypatch):
    monkeypatch.setenv("INTEGRATION_ENCRYPTION_KEY", "route-sandbox-key")
    from backend.config import get_config

    get_config.cache_clear()
    fake = FakeSupabase()
    mgr = SandboxManager(provider_factory=lambda s, sec: FakeProvider(s, sec))
    mgr.set_tenant_config(
        "tenant-1",
        {"provider": "modal", "autonomy_mode": "auto_read_test"},
        secrets={"runner_token": "runner-tok-1"},
    )
    app = FastAPI()
    sandbox_routes.register_sandbox_routes(
        app, lambda: "tenant-1", lambda: fake, None, manager=mgr
    )
    yield TestClient(app, raise_server_exceptions=False), fake, mgr
    GLOBAL_REGISTRY.unregister("tenant-1")
    get_config.cache_clear()


class TestConfigRoutes:
    def test_get_default_config_masked(self, harness):
        tc, _fake, _mgr = harness
        resp = tc.get("/api/v1/sandboxes/config")
        assert resp.status_code == 200
        body = resp.json()
        assert body["has_secrets"] is False
        assert "encrypted_secrets" not in body
        assert body["provider"] in ("disabled", "modal", "e2b", "remote_mcp", "local_runner")

    def test_put_encrypts_and_get_masks(self, harness):
        tc, fake, _mgr = harness
        resp = tc.put("/api/v1/sandboxes/config", json={
            "provider": "modal", "cpu_cores": 8,
            "secrets": {"modal_token_id": "mid", "modal_token_secret": "msecret"},
        })
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["has_secrets"] is True
        assert body["cpu_cores"] == 8
        assert "msecret" not in resp.text
        row = fake.table(store.CONFIG_TABLE).rows[0]
        assert "msecret" not in row["encrypted_secrets"]
        assert decrypt_secrets(row["encrypted_secrets"])["modal_token_secret"] == "msecret"
        resp2 = tc.get("/api/v1/sandboxes/config")
        assert resp2.json()["has_secrets"] is True
        assert "msecret" not in resp2.text

    def test_put_invalid_provider_400(self, harness):
        tc, _fake, _mgr = harness
        resp = tc.put("/api/v1/sandboxes/config", json={"provider": "nope"})
        assert resp.status_code == 400


class TestTestEndpoint:
    def test_test_boots_runs_and_tears_down(self, harness):
        tc, _fake, mgr = harness
        resp = tc.post("/api/v1/sandboxes/test", json={})
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["status"] == "running"
        assert isinstance(body["latency_ms"], int)
        assert "uname -a" in body["output"]
        assert mgr.list_session_infos("tenant-1") == []  # torn down


class TestSessionRoutes:
    @pytest.mark.asyncio
    async def _start(self, mgr):
        return await mgr.start_session("tenant-1", chat_id="chat-9")

    def test_list_pause_approve_delete(self, harness):
        tc, _fake, mgr = harness
        import asyncio

        info = asyncio.run(mgr.start_session("tenant-1", chat_id="chat-9"))
        resp = tc.get("/api/v1/sandboxes/sessions")
        assert resp.status_code == 200
        ids = [s["id"] for s in resp.json()["sessions"]]
        assert info.session_id in ids

        mgr.record_approval_request(info.session_id, {"tool_name": "sandbox_exec"})
        resp = tc.post(
            f"/api/v1/sandboxes/sessions/{info.session_id}/approve",
            json={"approve": True, "tool_name": "sandbox_exec"},
        )
        assert resp.status_code == 200
        assert resp.json()["status"] == "approved"
        assert resp.json()["resolved"] == 1

        resp = tc.post(f"/api/v1/sandboxes/sessions/{info.session_id}/pause")
        assert resp.status_code == 200
        assert resp.json()["status"] == "paused"

        resp = tc.delete(f"/api/v1/sandboxes/sessions/{info.session_id}")
        assert resp.status_code == 200
        assert resp.json()["status"] == "stopped"

    def test_pause_unknown_session_404(self, harness):
        tc, _fake, _mgr = harness
        resp = tc.post("/api/v1/sandboxes/sessions/does-not-exist/pause")
        assert resp.status_code == 404

    def test_approve_unknown_session_404(self, harness):
        tc, _fake, _mgr = harness
        resp = tc.post(
            "/api/v1/sandboxes/sessions/does-not-exist/approve", json={"approve": True}
        )
        assert resp.status_code == 404


class TestRunnerWebSocket:
    def test_ws_accepts_valid_runner_token(self, harness):
        tc, _fake, _mgr = harness
        with tc.websocket_connect(
            "/api/v1/sandboxes/runner/ws?tenant_id=tenant-1&token=runner-tok-1"
        ):
            assert GLOBAL_REGISTRY.is_connected("tenant-1") is True
        assert GLOBAL_REGISTRY.is_connected("tenant-1") is False

    def test_ws_rejects_bad_token(self, harness):
        tc, _fake, _mgr = harness
        with pytest.raises(WebSocketDisconnect), tc.websocket_connect(
            "/api/v1/sandboxes/runner/ws?tenant_id=tenant-1&token=wrong"
        ):
            pass
