"""Route & security tests for /api/v1/github-app/* endpoints."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.routes import code_intel as code_intel_routes
from backend.routes import github_app as gh_routes
from backend.tests.test_integrations_routes import _FakeTable
from backend.tests.test_oauth_service import FakeRedis


class _FakeSupabase:
    def __init__(self) -> None:
        self.tables = {
            "github_app_installations": _FakeTable(),
            "github_app_repos": _FakeTable(),
        }

    def table(self, name: str):
        return self.tables[name]


def _make_app(sb, redis, cfg):
    app = FastAPI()
    app.state.redis = redis
    gh_routes.register_github_app_routes(
        app,
        lambda: "tenant-1",
        lambda: sb,
        cfg,
    )
    return app


def _cfg(secret: str = "whsec_test") -> SimpleNamespace:
    return SimpleNamespace(
        github_app_id="1001",
        github_app_slug="veraxi-app",
        github_app_client_id="Iv1.app",
        github_app_client_secret="sec",
        github_app_private_key="---PEM---",
        github_app_private_key_path="",
        github_app_private_key_secondary="",
        github_app_webhook_secret=secret,
        github_app_max_repo_mb=50,
        oauth_redirect_base_url="https://api.veraxi.me",
        public_app_url="https://veraxi.me",
        worker_mode="inline",
    )


def _sign(secret: str, body: bytes) -> str:
    return "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


def test_status_reports_configured_and_installations():
    sb = _FakeSupabase()
    redis = FakeRedis()
    app = _make_app(sb, redis, _cfg())
    client = TestClient(app)

    resp = client.get("/api/v1/github-app/status")
    assert resp.status_code == 200
    data = resp.json()
    assert data["configured"] is True
    assert data["app_slug"] == "veraxi-app"
    assert data["installations"] == []


def test_callback_rejects_unowned_installation_id_idor():
    sb = _FakeSupabase()
    redis = FakeRedis()
    cfg = _cfg()
    app = _make_app(sb, redis, cfg)
    client = TestClient(app)

    with (
        patch.object(
            gh_routes.gh_client,
            "consume_install_state",
            AsyncMock(return_value={"tenant_id": "tenant-1", "verifier": "v1"}),
        ),
        patch.object(
            gh_routes.gh_client,
            "exchange_user_oauth_code",
            AsyncMock(return_value={"access_token": "ghu_user_tok", "expires_in": 28800}),
        ),
        patch.object(
            gh_routes.gh_client,
            "list_user_installations",
            AsyncMock(return_value=[{"id": 111, "account": {"id": 1, "login": "me"}}]),
        ),
    ):
        # Attacker passes foreign installation_id=99999
        resp = client.get(
            "/api/v1/github-app/callback?code=abc&installation_id=99999&state=st"
        )

    assert resp.status_code == 200
    assert '"provider": "github_app"' in resp.text
    assert "access_denied" in resp.text
    assert sb.tables["github_app_installations"].rows == []


def test_callback_handles_setup_action_request_and_update():
    sb = _FakeSupabase()
    redis = FakeRedis()
    app = _make_app(sb, redis, _cfg())
    client = TestClient(app)

    r_req = client.get(
        "/api/v1/github-app/callback?setup_action=request&installation_id=123"
    )
    assert r_req.status_code == 200
    assert '"status": "pending"' in r_req.text
    assert '"provider": "github_app"' in r_req.text

    r_upd = client.get(
        "/api/v1/github-app/callback?setup_action=update&installation_id=123"
    )
    assert r_upd.status_code == 200
    assert '"status": "connected"' in r_upd.text
    assert '"provider": "github_app"' in r_upd.text


def test_callback_binds_owned_installation_id():
    sb = _FakeSupabase()
    redis = FakeRedis()
    cfg = _cfg()
    app = _make_app(sb, redis, cfg)
    client = TestClient(app)

    with (
        patch.object(
            gh_routes.gh_client,
            "consume_install_state",
            AsyncMock(return_value={"tenant_id": "tenant-1", "verifier": "v1"}),
        ),
        patch.object(
            gh_routes.gh_client,
            "exchange_user_oauth_code",
            AsyncMock(return_value={"access_token": "ghu_user_tok", "expires_in": 28800}),
        ),
        patch.object(
            gh_routes.gh_client,
            "list_user_installations",
            AsyncMock(
                return_value=[
                    {
                        "id": 555,
                        "repository_selection": "selected",
                        "permissions": {"contents": "read", "metadata": "read"},
                        "account": {"id": 7, "login": "acme", "type": "Organization"},
                    }
                ]
            ),
        ),
    ):
        resp = client.get(
            "/api/v1/github-app/callback?code=abc&installation_id=555&state=st"
        )

    assert resp.status_code == 200
    assert '"status": "connected"' in resp.text
    rows = sb.tables["github_app_installations"].rows
    assert len(rows) == 1
    assert rows[0]["installation_id"] == 555
    assert rows[0]["github_account_login"] == "acme"


def test_webhook_fails_closed_without_secret_or_bad_signature():
    sb = _FakeSupabase()
    redis = FakeRedis()

    app_no_secret = _make_app(sb, redis, _cfg(secret=""))
    r1 = TestClient(app_no_secret).post("/api/v1/github-app/webhook", content=b"{}")
    assert r1.status_code == 503

    app_with_secret = _make_app(sb, redis, _cfg(secret="real_secret"))
    r2 = TestClient(app_with_secret).post(
        "/api/v1/github-app/webhook",
        content=b"{}",
        headers={"X-Hub-Signature-256": "sha256=deadbeef"},
    )
    assert r2.status_code == 401


def test_webhook_deduplicates_delivery_and_purges_removed_repo():
    sb = _FakeSupabase()
    redis = FakeRedis()
    sb.tables["github_app_installations"].rows.append(
        {"tenant_id": "tenant-1", "installation_id": 555}
    )
    sb.tables["github_app_repos"].rows.append(
        {"tenant_id": "tenant-1", "installation_id": 555, "repo_full_name": "acme/secret"}
    )
    app = _make_app(sb, redis, _cfg(secret="whsec"))
    client = TestClient(app)

    body = json.dumps(
        {
            "action": "removed",
            "installation": {"id": 555},
            "repositories_removed": [{"full_name": "acme/secret"}],
        }
    ).encode("utf-8")
    headers = {
        "X-Hub-Signature-256": _sign("whsec", body),
        "X-GitHub-Event": "installation_repositories",
        "X-GitHub-Delivery": "deliv-1",
    }

    with patch.object(
        gh_routes, "purge_github_app_repo", AsyncMock()
    ) as purge_mock:
        r1 = client.post("/api/v1/github-app/webhook", content=body, headers=headers)
        r2 = client.post("/api/v1/github-app/webhook", content=body, headers=headers)

    assert r1.status_code == 202
    assert r1.json()["status"] == "removed"
    assert purge_mock.await_count == 1
    assert sb.tables["github_app_repos"].rows == []
    assert r2.status_code == 202
    assert r2.json()["status"] == "duplicate"


def test_jobs_endpoint_enforces_tenant_ownership_and_serializes_failures():
    sb = _FakeSupabase()
    redis = FakeRedis()
    redis.kv["ghapp:job:job-1"] = "other-tenant"
    redis.kv["ghapp:job:job-2"] = "tenant-1"
    app = _make_app(sb, redis, _cfg())
    client = TestClient(app)

    # Cross-tenant IDOR must return 404
    r_idor = client.get("/api/v1/github-app/jobs/job-1")
    assert r_idor.status_code == 404

    class _FakeStatus:
        value = "complete"

    class _FakeJob:
        def __init__(self, job_id, redis=None):
            self.job_id = job_id

        async def status(self):
            return _FakeStatus()

        async def info(self):
            return SimpleNamespace(success=False, result=RuntimeError("tarball too large"))

    with patch("arq.jobs.Job", _FakeJob):
        r_fail = client.get("/api/v1/github-app/jobs/job-2")

    assert r_fail.status_code == 200
    assert r_fail.json()["status"] == "failed"
    assert "tarball too large" in r_fail.json()["error"]


def test_disconnect_repo_endpoint_purges_and_deletes():
    sb = _FakeSupabase()
    redis = FakeRedis()
    sb.tables["github_app_repos"].rows.append(
        {"tenant_id": "tenant-1", "installation_id": 555, "repo_full_name": "acme/demo"}
    )
    app = _make_app(sb, redis, _cfg())
    client = TestClient(app)

    with patch.object(gh_routes, "purge_github_app_repo", AsyncMock()) as purge_mock:
        r1 = client.delete("/api/v1/github-app/repos/acme/demo")
        r2 = client.delete("/api/v1/github-app/repos/acme/demo")

    assert r1.status_code == 200
    assert r1.json()["status"] == "deleted"
    assert purge_mock.await_count == 1
    assert r2.status_code == 404


def test_code_file_serves_github_app_pinned_sha_and_caches_in_redis():
    sb = _FakeSupabase()
    redis = FakeRedis()
    sb.tables["github_app_repos"].rows.append(
        {
            "tenant_id": "tenant-1",
            "installation_id": 555,
            "repo_full_name": "acme/demo",
            "default_branch": "main",
        }
    )
    app = FastAPI()
    app.state.redis = redis
    code_intel_routes.register_code_intel_routes(
        app, lambda: "tenant-1", lambda: sb, _cfg()
    )
    client = TestClient(app)

    with (
        patch.object(
            code_intel_routes,
            "indexed_file",
            return_value={
                "path": "src/app.py",
                "language": "python",
                "repo_key": "acme/demo",
            },
        ),
        patch.object(
            code_intel_routes,
            "_resolve_code_file_on_disk",
            return_value=None,
        ),
        patch.object(
            code_intel_routes,
            "_default_neo4j_client",
            return_value=object(),
        ),
        patch(
            "backend.ingestion.code_graph.read_index_meta",
            return_value={"kind": "github_app", "source_commit": "sha_abc"},
        ),
        patch.object(
            gh_routes.gh_client,
            "get_installation_token",
            AsyncMock(return_value="ghs_tok"),
        ),
        patch.object(
            gh_routes.gh_client,
            "fetch_file_at_ref",
            AsyncMock(return_value="def hello():\n    return 42\n"),
        ) as fetch_mock,
    ):
        r1 = client.get("/api/v1/code/file?path=src/app.py&repo_key=acme/demo")
        r2 = client.get("/api/v1/code/file?path=src/app.py&repo_key=acme/demo")

    assert r1.status_code == 200
    d1 = r1.json()
    assert d1["source"] == "github_app"
    assert d1["line_count"] == 2
    assert d1["content"] == "def hello():\n    return 42\n"

    assert r2.status_code == 200
    assert r2.json()["source"] == "github_app"
    assert fetch_mock.await_count == 1


def test_vuln_report_uses_github_app_dependencies_snapshot():
    sb = _FakeSupabase()
    snapshot = [
        {
            "name": "lodash",
            "version": "4.17.20",
            "ecosystem": "npm",
            "source_file": "package.json",
        }
    ]
    sb.tables["github_app_repos"].rows.append(
        {
            "tenant_id": "tenant-1",
            "installation_id": 555,
            "repo_full_name": "acme/demo",
            "dependencies_snapshot": snapshot,
        }
    )
    app = FastAPI()
    code_intel_routes.register_code_intel_routes(
        app, lambda: "tenant-1", lambda: sb, _cfg()
    )
    client = TestClient(app)

    seen: list[list[dict]] = []

    def _fake_vuln_report(deps, tenant_id, repo=None):
        seen.append(deps)
        return {
            "dependencies_checked": len(deps),
            "findings": [],
            "matched_count": 0,
            "unknown_count": 0,
            "kev_count": 0,
            "tenant_id": tenant_id,
        }

    with patch.object(code_intel_routes, "vuln_report", _fake_vuln_report):
        resp = client.post("/api/v1/vuln/report", json={"repo": "acme/demo"})

    assert resp.status_code == 200
    assert seen == [snapshot]
    assert resp.json()["dependencies_checked"] == 1


def test_webhook_installation_deleted_purges_all_repos_and_invalidates_token():
    sb = _FakeSupabase()
    redis = FakeRedis()
    redis.kv["ghapp:iat:555"] = "cached-token"
    sb.tables["github_app_installations"].rows.append(
        {"tenant_id": "tenant-1", "installation_id": 555}
    )
    sb.tables["github_app_repos"].rows.extend(
        [
            {"tenant_id": "tenant-1", "installation_id": 555, "repo_full_name": "acme/one"},
            {"tenant_id": "tenant-1", "installation_id": 555, "repo_full_name": "acme/two"},
        ]
    )
    app = _make_app(sb, redis, _cfg(secret="whsec"))
    client = TestClient(app)

    body = json.dumps(
        {
            "action": "deleted",
            "installation": {"id": 555},
        }
    ).encode("utf-8")
    headers = {
        "X-Hub-Signature-256": _sign("whsec", body),
        "X-GitHub-Event": "installation",
        "X-GitHub-Delivery": "deliv-inst-del",
    }

    with patch.object(
        gh_routes, "purge_github_app_repo", AsyncMock()
    ) as purge_mock:
        resp = client.post("/api/v1/github-app/webhook", content=body, headers=headers)

    assert resp.status_code == 202
    assert purge_mock.await_count == 2
    assert sb.tables["github_app_repos"].rows == []
    assert sb.tables["github_app_installations"].rows == []
    assert "ghapp:iat:555" not in redis.kv


def test_webhook_push_enqueues_arq_job_and_returns_202():
    sb = _FakeSupabase()
    redis = FakeRedis()
    redis.enqueue_job = AsyncMock(return_value=SimpleNamespace(job_id="job-push-1"))
    sb.tables["github_app_repos"].rows.append(
        {
            "tenant_id": "tenant-1",
            "installation_id": 555,
            "repo_full_name": "acme/demo",
            "auto_sync_on_push": True,
        }
    )
    cfg = _cfg(secret="whsec")
    cfg.worker_mode = "arq"
    app = _make_app(sb, redis, cfg)
    client = TestClient(app)

    body = json.dumps(
        {
            "ref": "refs/heads/main",
            "after": "deadbeef1234",
            "repository": {"full_name": "acme/demo"},
            "installation": {"id": 555},
        }
    ).encode("utf-8")
    headers = {
        "X-Hub-Signature-256": _sign("whsec", body),
        "X-GitHub-Event": "push",
        "X-GitHub-Delivery": "deliv-push-1",
    }

    resp = client.post("/api/v1/github-app/webhook", content=body, headers=headers)

    assert resp.status_code == 202
    assert resp.json()["status"] == "queued"
    redis.enqueue_job.assert_awaited_once_with(
        "sync_github_app_push_task",
        555,
        "acme/demo",
        "deadbeef1234",
        "main",
    )


@pytest.mark.asyncio
async def test_sync_github_app_push_task_skips_when_debounce_lock_held():
    from backend.worker import sync_github_app_push_task

    redis = FakeRedis()
    redis.kv["ghapp:push-lock:555:acme/demo"] = "prev_sha"
    cfg = SimpleNamespace(
        supabase_url="https://example.supabase.co",
        supabase_service_key="service-key",
    )

    with (
        patch("backend.worker.get_config", return_value=cfg),
        patch("supabase.create_client", return_value=_FakeSupabase()),
    ):
        result = await sync_github_app_push_task(
            {"redis": redis},
            555,
            "acme/demo",
            "new_sha",
            "main",
        )

    assert result["status"] == "debounced"
    assert result["repo"] == "acme/demo"


@pytest.mark.asyncio
async def test_valid_user_token_serializes_concurrent_refresh_under_redis_lock():
    from backend.services import github_app_store as gh_store

    sb = _FakeSupabase()
    redis = FakeRedis()
    cfg = _cfg()
    expired_iso = (datetime.now(UTC) - timedelta(minutes=5)).isoformat()
    inst = gh_store.upsert_installation(
        sb,
        "tenant-1",
        installation_id=555,
        account_id=7,
        account_login="acme",
        account_type="Organization",
        repository_selection="selected",
        permissions={"contents": "read"},
        user_tokens={"access_token": "ghu_old", "refresh_token": "ghr_old"},
        user_token_expires_at=expired_iso,
        status="active",
    )

    async def _slow_refresh(c, rt):
        await asyncio.sleep(0.05)
        return {
            "access_token": "ghu_new",
            "refresh_token": "ghr_new",
            "expires_in": 28800,
        }

    with patch.object(
        gh_routes.gh_client, "refresh_user_token", side_effect=_slow_refresh
    ) as refresh_mock:
        t1, t2 = await asyncio.gather(
            gh_routes._valid_user_token(cfg, sb, redis, inst),
            gh_routes._valid_user_token(cfg, sb, redis, inst),
        )

    assert t1 == "ghu_new"
    assert t2 == "ghu_new"
    assert refresh_mock.await_count == 1
    assert "ghapp:refresh-lock:tenant-1:555" not in redis.kv


def test_webhook_installation_deleted_enqueues_arq_purge_when_arq_enabled():
    sb = _FakeSupabase()
    redis = FakeRedis()
    redis.enqueue_job = AsyncMock(return_value=SimpleNamespace(job_id="job-purge-1"))
    redis.kv["ghapp:iat:555"] = "cached-token"
    sb.tables["github_app_installations"].rows.append(
        {"tenant_id": "tenant-1", "installation_id": 555}
    )
    sb.tables["github_app_repos"].rows.extend(
        [
            {"tenant_id": "tenant-1", "installation_id": 555, "repo_full_name": "acme/one"},
            {"tenant_id": "tenant-1", "installation_id": 555, "repo_full_name": "acme/two"},
        ]
    )
    cfg = _cfg(secret="whsec")
    cfg.worker_mode = "arq"
    app = _make_app(sb, redis, cfg)
    client = TestClient(app)

    body = json.dumps(
        {
            "action": "deleted",
            "installation": {"id": 555},
        }
    ).encode("utf-8")
    headers = {
        "X-Hub-Signature-256": _sign("whsec", body),
        "X-GitHub-Event": "installation",
        "X-GitHub-Delivery": "deliv-inst-del-arq",
    }

    resp = client.post("/api/v1/github-app/webhook", content=body, headers=headers)

    assert resp.status_code == 202
    assert resp.json()["status"] == "queued"
    assert sb.tables["github_app_repos"].rows == []
    assert sb.tables["github_app_installations"].rows == []
    assert "ghapp:iat:555" not in redis.kv
    redis.enqueue_job.assert_awaited_once_with(
        "purge_github_app_repos_task",
        [["tenant-1", "acme/one"], ["tenant-1", "acme/two"]],
    )
