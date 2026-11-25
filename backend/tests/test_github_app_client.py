"""Unit tests for backend.services.github_app_client."""

from __future__ import annotations

import io
import tarfile
import time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from backend.services import github_app_client as gh_client


def _generate_rsa_pem() -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return pem.decode("utf-8")


class _FakeRedis:
    def __init__(self) -> None:
        self.kv: dict[str, str] = {}

    async def get(self, key: str):
        return self.kv.get(key)

    async def setex(self, key: str, ttl: int, value: str):
        self.kv[key] = value
        return True

    async def set(self, key: str, value: str, nx: bool = False, ex: int | None = None):
        if nx and key in self.kv:
            return None
        self.kv[key] = value
        return True

    async def delete(self, *keys: str):
        for k in keys:
            self.kv.pop(k, None)
        return len(keys)


def _config(pem: str) -> SimpleNamespace:
    return SimpleNamespace(
        github_app_id="12345",
        github_app_slug="veraxi-test",
        github_app_client_id="Iv1.testclient",
        github_app_client_secret="secret",
        github_app_private_key=pem,
        github_app_private_key_path="",
        github_app_private_key_secondary="",
        github_app_webhook_secret="whsec",
        github_app_max_repo_mb=10,
        oauth_redirect_base_url="https://api.veraxi.me",
        public_app_url="https://veraxi.me",
    )


def test_mint_app_jwt_applies_clock_skew_buffer():
    pem = _generate_rsa_pem()
    cfg = _config(pem)
    now = int(time.time())
    token = gh_client.mint_app_jwt(cfg)
    decoded = jwt.decode(token, options={"verify_signature": False})
    assert decoded["iss"] == "Iv1.testclient"
    assert decoded["iat"] <= now - 55
    assert decoded["exp"] - decoded["iat"] == 600


@pytest.mark.asyncio
async def test_get_installation_token_caches_in_redis():
    pem = _generate_rsa_pem()
    cfg = _config(pem)
    redis = _FakeRedis()
    mint_mock = AsyncMock(return_value="ghs_cached_token_1")

    with patch.object(gh_client, "_mint_installation_token", mint_mock):
        t1 = await gh_client.get_installation_token(cfg, redis, 42)
        t2 = await gh_client.get_installation_token(cfg, redis, 42)

    assert t1 == "ghs_cached_token_1"
    assert t2 == "ghs_cached_token_1"
    assert mint_mock.await_count == 1


def _build_tar_gz(entries: list[tuple[str, bytes | None, str]]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, content, kind in entries:
            info = tarfile.TarInfo(name=name)
            if kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = "/etc/passwd"
                tf.addfile(info)
            elif kind == "file" and content is not None:
                info.size = len(content)
                tf.addfile(info, io.BytesIO(content))
    return buf.getvalue()


def test_safe_extract_tarball_extracts_valid_files_and_skips_symlinks(tmp_path: Path):
    archive = _build_tar_gz(
        [
            ("owner-repo-sha/README.md", b"# Hello", "file"),
            ("owner-repo-sha/evil_link", None, "symlink"),
        ]
    )
    gh_client._safe_extract_tarball(archive, tmp_path)
    assert (tmp_path / "README.md").read_text(encoding="utf-8") == "# Hello"
    assert not (tmp_path / "evil_link").exists()


def test_safe_extract_tarball_rejects_path_traversal(tmp_path: Path):
    archive = _build_tar_gz(
        [
            ("owner-repo-sha/../../etc/cron.d/pwn", b"bad", "file"),
        ]
    )
    with pytest.raises(gh_client.GitHubAppError):
        gh_client._safe_extract_tarball(archive, tmp_path)


@pytest.mark.asyncio
async def test_exchange_user_oauth_code_omits_pkce_verifier():
    cfg = _config(_generate_rsa_pem())
    captured: dict = {}

    class _FakeResp:
        status_code = 200

        def __init__(self):
            self.headers: dict = {}

        def raise_for_status(self):
            return None

        def json(self):
            return {"access_token": "ghu_123", "expires_in": 28800}

    async def _fake_req(method, url, *, headers, data=None, **kwargs):
        captured["data"] = data
        return _FakeResp()

    with patch.object(gh_client, "_request_with_backoff", side_effect=_fake_req):
        tok = await gh_client.exchange_user_oauth_code(cfg, "auth_code_1")

    assert tok["access_token"] == "ghu_123"
    assert "code_verifier" not in captured["data"]


@pytest.mark.asyncio
async def test_mint_installation_token_falls_back_to_secondary_key():
    import httpx

    pem1 = _generate_rsa_pem()
    pem2 = _generate_rsa_pem()
    cfg = _config(pem1)
    cfg.github_app_private_key_secondary = pem2
    calls = 0

    class _FakeResp:
        status_code = 201

        def __init__(self):
            self.headers: dict = {}

        def json(self):
            return {"token": "ghs_secondary_ok"}

    async def _fake_req(*args, **kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            req = httpx.Request("POST", "https://api.github.com/app/installations/1/access_tokens")
            resp = httpx.Response(401, request=req)
            raise httpx.HTTPStatusError("unauthorized", request=req, response=resp)
        return _FakeResp()

    with patch.object(gh_client, "_request_with_backoff", side_effect=_fake_req):
        token = await gh_client._mint_installation_token(cfg, 1)

    assert token == "ghs_secondary_ok"
    assert calls == 2


@pytest.mark.asyncio
async def test_exchange_user_oauth_code_raises_config_error_on_404():
    import httpx

    cfg = _config(_generate_rsa_pem())
    req = httpx.Request("POST", "https://github.com/login/oauth/access_token")
    resp = httpx.Response(404, request=req)
    exc = httpx.HTTPStatusError("not found", request=req, response=resp)

    with patch.object(gh_client, "_request_with_backoff", side_effect=exc):
        with pytest.raises(gh_client.GitHubAppConfigError):
            await gh_client.exchange_user_oauth_code(cfg, "auth_code_1")


@pytest.mark.asyncio
async def test_exchange_user_oauth_code_raises_config_error_on_bad_client_creds():
    cfg = _config(_generate_rsa_pem())

    class _FakeResp:
        def json(self):
            return {"error": "incorrect_client_credentials"}

    with patch.object(
        gh_client, "_request_with_backoff", AsyncMock(return_value=_FakeResp())
    ):
        with pytest.raises(gh_client.GitHubAppConfigError):
            await gh_client.exchange_user_oauth_code(cfg, "auth_code_1")


@pytest.mark.asyncio
async def test_consume_install_state_raises_state_error_when_missing():
    redis = _FakeRedis()
    with pytest.raises(gh_client.GitHubAppStateError):
        await gh_client.consume_install_state(redis, "nonexistent-state")


@pytest.mark.asyncio
async def test_verify_app_credentials_detects_client_id_mismatch():
    import httpx

    cfg = _config(_generate_rsa_pem())

    class _FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            self.calls = 0

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def get(self, url, headers=None):
            self.calls += 1
            if self.calls == 1:
                return httpx.Response(404, request=httpx.Request("GET", url))
            return httpx.Response(
                200,
                json={"id": 12345, "slug": "veraxi-test", "client_id": "Iv1.realclient"},
                request=httpx.Request("GET", url),
            )

    with patch("httpx.AsyncClient", _FakeAsyncClient):
        ok, msg = await gh_client.verify_app_credentials(cfg)

    assert ok is False
    assert "GITHUB_APP_CLIENT_ID mismatch" in msg


@pytest.mark.asyncio
async def test_verify_app_credentials_succeeds_when_matching():
    import httpx

    cfg = _config(_generate_rsa_pem())

    class _FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def get(self, url, headers=None):
            return httpx.Response(
                200,
                json={"id": 12345, "slug": "veraxi-test", "client_id": "Iv1.testclient"},
                request=httpx.Request("GET", url),
            )

    with patch("httpx.AsyncClient", _FakeAsyncClient):
        ok, msg = await gh_client.verify_app_credentials(cfg)

    assert ok is True
    assert "veraxi-test" in msg
