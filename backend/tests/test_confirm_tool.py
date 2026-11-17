"""Tests for POST /api/chat/confirm-tool (Phase 5 backend gate)."""

from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.mcp_server.tools import github_tools
from backend.routes import chat as chat_routes


class _FakeLimiter:
    def limit(self, *_a, **_k):
        def decorator(fn):
            return fn

        return decorator


@pytest.fixture()
def client():
    app = FastAPI()
    config = SimpleNamespace(
        rate_limit_chat="100/day",
        rate_limit_sse="10/minute",
        rate_limit_ingest="50/day",
        rate_limit_artifact_complete="20/minute",
    )
    chat_routes.register_chat_routes(
        app, lambda: "tenant-1", lambda: None, _FakeLimiter(), config
    )
    return TestClient(app, raise_server_exceptions=False)


class TestConfirmTool:
    def test_reject_executes_nothing(self, client, monkeypatch):
        async def fake_execute(*a, **k):  # pragma: no cover - must not run
            raise AssertionError("rejected tool must not execute")

        monkeypatch.setattr(github_tools, "execute_github_tool", fake_execute)
        resp = client.post(
            "/api/chat/confirm-tool",
            json={
                "tool_name": "github_create_issue",
                "args": {"repo": "o/r", "title": "x"},
                "approve": False,
            },
        )
        assert resp.status_code == 200
        assert resp.json()["status"] == "rejected"

    def test_approve_executes_once(self, client, monkeypatch):
        calls = []

        async def fake_execute(name, args, tenant_id, supabase=None):
            calls.append((name, args))
            return "Created issue #9"

        monkeypatch.setattr(github_tools, "execute_github_tool", fake_execute)
        resp = client.post(
            "/api/chat/confirm-tool",
            json={
                "tool_name": "github_create_issue",
                "args": {"repo": "o/r", "title": "x"},
                "approve": True,
            },
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "executed"
        assert "Created issue #9" in body["result"]
        assert calls == [("github_create_issue", {"repo": "o/r", "title": "x"})]

    def test_approve_non_gated_tool_rejected(self, client):
        resp = client.post(
            "/api/chat/confirm-tool",
            json={
                "tool_name": "github_search_code",
                "args": {"query": "x"},
                "approve": True,
            },
        )
        assert resp.status_code == 400
