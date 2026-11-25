"""GitHub App client: RS256 App JWTs, Installation Access Tokens, OAuth, and API helpers.

Uses ``PyJWT``, ``cryptography``, and ``httpx`` (already in ``pyproject.toml``)
so no new dependencies are required. Tokens and private keys are never logged.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import secrets as stdlib_secrets
import tarfile
import time
from pathlib import Path
from typing import Any

import httpx
import jwt
import sentry_sdk

logger = logging.getLogger(__name__)

GITHUB_API_BASE = "https://api.github.com"
GITHUB_WEB_BASE = "https://github.com"
_API_VERSION = "2022-11-28"
_IAT_CACHE_TTL_SEC = 3000  # 50 minutes (10-min buffer before GitHub's 60-min expiry)
_IAT_LOCK_TTL_SEC = 15
_STATE_TTL_SEC = 600
_MAX_RETRIES = 3


class GitHubAppError(Exception):
    """Raised on GitHub App configuration, auth, or API failures."""


class GitHubAppConfigError(GitHubAppError):
    """Raised when server-side GitHub App credentials or redirect URIs are invalid."""


class GitHubAppStateError(GitHubAppError):
    """Raised when an OAuth installation state token is missing or expired."""


class GitHubAppRateLimitError(GitHubAppError):
    """Raised when GitHub API rate limits cannot be satisfied after retries."""


def is_configured(config: Any) -> bool:
    """True when the minimum GitHub App credentials are present."""
    if not config:
        return False
    has_id = bool(getattr(config, "github_app_id", "") or getattr(config, "github_app_client_id", ""))
    has_slug = bool(getattr(config, "github_app_slug", ""))
    has_key = bool(_load_private_keys(config))
    has_oauth = bool(
        getattr(config, "github_app_client_id", "")
        and getattr(config, "github_app_client_secret", "")
    )
    return has_id and has_slug and has_key and has_oauth


def _normalize_pem(raw: str) -> str:
    return raw.strip().replace("\\n", "\n")


def _load_private_keys(config: Any) -> list[str]:
    """Return ordered list of configured PEM private keys (primary, optional secondary)."""
    keys: list[str] = []
    inline = getattr(config, "github_app_private_key", "") or ""
    if inline.strip():
        keys.append(_normalize_pem(inline))
    key_path = getattr(config, "github_app_private_key_path", "") or ""
    if not keys and key_path.strip():
        try:
            content = Path(key_path.strip()).read_text(encoding="utf-8")
            if content.strip():
                keys.append(_normalize_pem(content))
        except OSError as exc:
            logger.warning("Failed to read GITHUB_APP_PRIVATE_KEY_PATH: %s", exc)
    secondary = getattr(config, "github_app_private_key_secondary", "") or ""
    if secondary.strip():
        keys.append(_normalize_pem(secondary))
    return keys


def mint_app_jwt(config: Any, *, key_index: int = 0) -> str:
    """Mint a short-lived RS256 App JWT with a 60s clock-skew buffer."""
    keys = _load_private_keys(config)
    if key_index >= len(keys):
        raise GitHubAppError("GitHub App private key is not configured")
    issuer = (
        getattr(config, "github_app_client_id", "")
        or getattr(config, "github_app_id", "")
    )
    if not issuer:
        raise GitHubAppError("GitHub App ID / Client ID is not configured")
    now = int(time.time())
    payload = {
        "iat": now - 60,
        "exp": now + 540,
        "iss": str(issuer),
    }
    return jwt.encode(payload, keys[key_index], algorithm="RS256")


def callback_uri(config: Any) -> str:
    """Return the backend callback URI for GitHub App OAuth + setup redirects."""
    base = (getattr(config, "oauth_redirect_base_url", "") or "").strip() or (
        getattr(config, "public_app_url", "") or ""
    ).strip()
    return f"{base.rstrip('/')}/api/v1/github-app/callback"


def _state_key(state: str) -> str:
    return f"ghapp:state:{state}"


async def build_install_url(config: Any, redis_client: Any, tenant_id: str) -> str:
    """Persist CSRF state in Redis and return the GitHub App install URL."""
    if not is_configured(config):
        raise GitHubAppError("GitHub App is not configured on this server")
    state = stdlib_secrets.token_urlsafe(32)
    payload = json.dumps({"tenant_id": tenant_id})
    await redis_client.setex(_state_key(state), _STATE_TTL_SEC, payload)
    slug = config.github_app_slug.strip("/")
    req = httpx.Request(
        "GET",
        f"{GITHUB_WEB_BASE}/apps/{slug}/installations/new",
        params={"state": state},
    )
    return str(req.url)


async def consume_install_state(redis_client: Any, state: str) -> dict[str, Any]:
    """Validate and consume a one-time state token from Redis."""
    if not state:
        raise GitHubAppStateError("Missing OAuth state")
    raw = await redis_client.get(_state_key(state))
    if raw is None:
        raise GitHubAppStateError("GitHub App state is invalid or expired")
    await redis_client.delete(_state_key(state))
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    data = json.loads(raw)
    if not data.get("tenant_id"):
        raise GitHubAppStateError("GitHub App state is missing tenant binding")
    return data


def _retry_delay_seconds(response: httpx.Response, attempt: int) -> float:
    retry_after = response.headers.get("Retry-After")
    if retry_after and retry_after.isdigit():
        return min(float(retry_after), 30.0)
    remaining = response.headers.get("X-RateLimit-Remaining")
    reset_at = response.headers.get("X-RateLimit-Reset")
    if remaining == "0" and reset_at and reset_at.isdigit():
        wait = max(1.0, float(int(reset_at) - int(time.time())))
        return min(wait, 30.0)
    return min(2.0 ** attempt, 8.0)


async def _request_with_backoff(
    method: str,
    url: str,
    *,
    headers: dict[str, str],
    params: dict[str, Any] | None = None,
    json_body: dict[str, Any] | None = None,
    data: dict[str, Any] | None = None,
    timeout: float = 30.0,
    follow_redirects: bool = True,
) -> httpx.Response:
    last_exc: Exception | None = None
    async with httpx.AsyncClient(
        timeout=timeout, follow_redirects=follow_redirects
    ) as client:
        for attempt in range(_MAX_RETRIES):
            try:
                response = await client.request(
                    method,
                    url,
                    headers=headers,
                    params=params,
                    json=json_body,
                    data=data,
                )
            except httpx.HTTPError as exc:
                last_exc = exc
                if attempt == _MAX_RETRIES - 1:
                    raise GitHubAppError(f"GitHub API request failed: {exc}") from exc
                await asyncio.sleep(min(2.0 ** attempt, 4.0))
                continue

            if response.status_code in (429, 502, 503, 504) or (
                response.status_code == 403
                and response.headers.get("X-RateLimit-Remaining") == "0"
            ):
                if attempt == _MAX_RETRIES - 1:
                    raise GitHubAppRateLimitError(
                        f"GitHub API rate-limited ({response.status_code})"
                    )
                await asyncio.sleep(_retry_delay_seconds(response, attempt))
                continue
            response.raise_for_status()
            return response
    raise GitHubAppError(f"GitHub API request failed: {last_exc}")


_CONFIG_OAUTH_ERRORS = frozenset(
    {"incorrect_client_credentials", "redirect_uri_mismatch"}
)


def _handle_github_http_error(exc: httpx.HTTPStatusError, context: str) -> GitHubAppError:
    """Translate an httpx HTTPStatusError into a typed GitHubAppError."""
    status = exc.response.status_code
    if status == 404 and context == "oauth_exchange":
        return GitHubAppConfigError(
            "GitHub OAuth token endpoint returned 404; verify GITHUB_APP_CLIENT_ID"
        )
    if status == 401 and context == "user_api":
        return GitHubAppError("GitHub user authorization token is invalid or expired")
    return GitHubAppError(f"GitHub {context} failed ({status})")


def _raise_oauth_payload_error(payload: dict[str, Any], action: str) -> None:
    """Raise a typed GitHubAppError when GitHub's OAuth JSON omits access_token."""
    err = str(payload.get("error") or f"{action}_failed")
    if err in _CONFIG_OAUTH_ERRORS:
        raise GitHubAppConfigError(f"GitHub {action} misconfigured ({err})")
    raise GitHubAppError(f"GitHub {action} failed ({err})")


async def exchange_user_oauth_code(
    config: Any, code: str
) -> dict[str, Any]:
    """Exchange a GitHub App OAuth code for a user-to-server token bundle."""
    body: dict[str, Any] = {
        "client_id": config.github_app_client_id,
        "client_secret": config.github_app_client_secret,
        "code": code,
        "redirect_uri": callback_uri(config),
    }
    try:
        resp = await _request_with_backoff(
            "POST",
            f"{GITHUB_WEB_BASE}/login/oauth/access_token",
            headers={"Accept": "application/json"},
            data=body,
        )
    except httpx.HTTPStatusError as exc:
        raise _handle_github_http_error(exc, "oauth_exchange") from exc
    payload = resp.json()
    if not payload.get("access_token"):
        _raise_oauth_payload_error(payload, "user OAuth exchange")
    return payload


async def refresh_user_token(config: Any, refresh_token: str) -> dict[str, Any]:
    """Refresh an expiring GitHub App user-to-server access token."""
    try:
        resp = await _request_with_backoff(
            "POST",
            f"{GITHUB_WEB_BASE}/login/oauth/access_token",
            headers={"Accept": "application/json"},
            data={
                "client_id": config.github_app_client_id,
                "client_secret": config.github_app_client_secret,
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
            },
        )
    except httpx.HTTPStatusError as exc:
        raise _handle_github_http_error(exc, "token_refresh") from exc
    payload = resp.json()
    if not payload.get("access_token"):
        _raise_oauth_payload_error(payload, "user token refresh")
    return payload


def _gh_headers(token: str, accept: str = "application/vnd.github+json") -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Accept": accept,
        "X-GitHub-Api-Version": _API_VERSION,
    }


async def list_user_installations(user_token: str) -> list[dict[str, Any]]:
    """Return all GitHub App installations accessible to the authenticated user."""
    installations: list[dict[str, Any]] = []
    page = 1
    while page <= 20:
        try:
            resp = await _request_with_backoff(
                "GET",
                f"{GITHUB_API_BASE}/user/installations",
                headers=_gh_headers(user_token),
                params={"per_page": 100, "page": page},
            )
        except httpx.HTTPStatusError as exc:
            raise _handle_github_http_error(exc, "user_api") from exc
        batch = resp.json().get("installations") or []
        installations.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return installations


async def list_user_installation_repos(
    user_token: str, installation_id: int
) -> list[dict[str, Any]]:
    """Return repositories in ``installation_id`` visible to the user."""
    repos: list[dict[str, Any]] = []
    page = 1
    while page <= 50:
        try:
            resp = await _request_with_backoff(
                "GET",
                f"{GITHUB_API_BASE}/user/installations/{installation_id}/repositories",
                headers=_gh_headers(user_token),
                params={"per_page": 100, "page": page},
            )
        except httpx.HTTPStatusError as exc:
            raise _handle_github_http_error(exc, "user_api") from exc
        batch = resp.json().get("repositories") or []
        repos.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return repos


async def list_installation_repos(token: str) -> list[dict[str, Any]]:
    """Return repositories granted to an installation using an Installation Token."""
    repos: list[dict[str, Any]] = []
    page = 1
    while page <= 50:
        resp = await _request_with_backoff(
            "GET",
            f"{GITHUB_API_BASE}/installation/repositories",
            headers=_gh_headers(token),
            params={"per_page": 100, "page": page},
        )
        batch = resp.json().get("repositories") or []
        repos.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return repos


async def _mint_installation_token(config: Any, installation_id: int) -> str:
    """Exchange App JWT for a downscoped read-only Installation Access Token."""
    keys = _load_private_keys(config)
    last_error: Exception | None = None
    for idx in range(len(keys)):
        app_jwt = mint_app_jwt(config, key_index=idx)
        try:
            resp = await _request_with_backoff(
                "POST",
                f"{GITHUB_API_BASE}/app/installations/{installation_id}/access_tokens",
                headers=_gh_headers(app_jwt),
                json_body={"permissions": {"contents": "read", "metadata": "read"}},
            )
            token = resp.json().get("token")
            if not token:
                raise GitHubAppError("GitHub did not return an installation token")
            return str(token)
        except httpx.HTTPStatusError as exc:
            last_error = exc
            if exc.response.status_code == 401 and idx + 1 < len(keys):
                continue
            raise GitHubAppError(
                f"Failed to mint installation token ({exc.response.status_code})"
            ) from exc
    raise GitHubAppError(f"Failed to mint installation token: {last_error}")


def _mint_jwt_with_issuer(config: Any, issuer: str) -> str:
    keys = _load_private_keys(config)
    if not keys:
        raise GitHubAppError("GitHub App private key is not configured")
    now = int(time.time())
    return jwt.encode(
        {"iat": now - 60, "exp": now + 540, "iss": str(issuer)},
        keys[0],
        algorithm="RS256",
    )


async def _diagnose_404_client_id(
    client: httpx.AsyncClient, config: Any
) -> tuple[bool, str]:
    app_id = (getattr(config, "github_app_id", "") or "").strip()
    client_id = (getattr(config, "github_app_client_id", "") or "").strip()
    if not app_id or app_id == client_id:
        return False, "GitHub App not found (404) for configured issuer"
    try:
        fallback_jwt = _mint_jwt_with_issuer(config, app_id)
        probe = await client.get(
            f"{GITHUB_API_BASE}/app", headers=_gh_headers(fallback_jwt)
        )
    except Exception as exc:
        return False, f"GitHub App credential check failed: {exc}"
    if probe.status_code == 200:
        return (
            False,
            (
                "GITHUB_APP_CLIENT_ID mismatch: GITHUB_APP_ID authenticated against "
                "GitHub, but GITHUB_APP_CLIENT_ID returned 404"
            ),
        )
    return False, f"GitHub App not found (404) and app_id probe returned {probe.status_code}"


async def verify_app_credentials(config: Any) -> tuple[bool, str]:
    """Verify configured GitHub App JWT + slug + client_id against ``GET /app``."""
    if not is_configured(config):
        return False, "GitHub App is not configured"
    try:
        app_jwt = mint_app_jwt(config)
    except Exception as exc:
        return False, f"Failed to mint GitHub App JWT: {exc}"

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                f"{GITHUB_API_BASE}/app", headers=_gh_headers(app_jwt)
            )
            if resp.status_code == 404:
                return await _diagnose_404_client_id(client, config)
            if resp.status_code != 200:
                return False, f"GitHub /app verification returned HTTP {resp.status_code}"
            info = resp.json()
    except Exception as exc:
        return False, f"GitHub /app verification failed: {exc}"

    actual_slug = str(info.get("slug") or "")
    expected_slug = (getattr(config, "github_app_slug", "") or "").strip("/")
    if expected_slug and actual_slug and actual_slug != expected_slug:
        return (
            False,
            f"GITHUB_APP_SLUG mismatch: configured '{expected_slug}', GitHub returned '{actual_slug}'",
        )
    actual_cid = str(info.get("client_id") or "")
    expected_cid = (getattr(config, "github_app_client_id", "") or "").strip()
    if expected_cid and actual_cid and actual_cid != expected_cid:
        return False, "GITHUB_APP_CLIENT_ID does not match GitHub App metadata"
    return True, f"GitHub App '{actual_slug or expected_slug}' credentials verified"


async def get_installation_token(
    config: Any, redis_client: Any, installation_id: int
) -> str:
    """Return a cached 1-hour Installation Access Token, refreshing under a lock."""
    cache_key = f"ghapp:iat:{installation_id}"
    if redis_client is not None:
        cached = await redis_client.get(cache_key)
        if cached:
            return cached.decode("utf-8") if isinstance(cached, bytes) else str(cached)

    lock_key = f"ghapp:iat:lock:{installation_id}"
    lock_acquired = True
    if redis_client is not None:
        lock_acquired = bool(
            await redis_client.set(lock_key, "1", nx=True, ex=_IAT_LOCK_TTL_SEC)
        )

    try:
        if not lock_acquired and redis_client is not None:
            await asyncio.sleep(0.25)
            cached = await redis_client.get(cache_key)
            if cached:
                return (
                    cached.decode("utf-8") if isinstance(cached, bytes) else str(cached)
                )
        token = await _mint_installation_token(config, installation_id)
        if redis_client is not None:
            await redis_client.setex(cache_key, _IAT_CACHE_TTL_SEC, token)
        return token
    finally:
        if redis_client is not None and lock_acquired:
            try:
                await redis_client.delete(lock_key)
            except Exception as exc:
                sentry_sdk.capture_exception(exc)


async def invalidate_installation_token(redis_client: Any, installation_id: int) -> None:
    if redis_client is not None:
        await redis_client.delete(f"ghapp:iat:{installation_id}")


async def get_branch_head_sha(
    token: str, repo_full_name: str, branch: str
) -> str | None:
    """Return the commit SHA for ``branch`` on ``repo_full_name``."""
    resp = await _request_with_backoff(
        "GET",
        f"{GITHUB_API_BASE}/repos/{repo_full_name}/commits/{branch}",
        headers=_gh_headers(token),
    )
    sha = resp.json().get("sha")
    return str(sha) if sha else None


async def compare_commits(
    token: str, repo_full_name: str, base_sha: str, head_sha: str
) -> dict[str, Any]:
    """Return GitHub's commit comparison payload for incremental push sync."""
    resp = await _request_with_backoff(
        "GET",
        f"{GITHUB_API_BASE}/repos/{repo_full_name}/compare/{base_sha}...{head_sha}",
        headers=_gh_headers(token),
    )
    return resp.json()


async def fetch_file_at_ref(
    token: str,
    repo_full_name: str,
    path: str,
    ref: str,
    *,
    max_bytes: int = 1_000_000,
) -> str | None:
    """Fetch a single UTF-8 file from GitHub at a pinned commit/ref."""
    clean_path = path.lstrip("/")
    resp = await _request_with_backoff(
        "GET",
        f"{GITHUB_API_BASE}/repos/{repo_full_name}/contents/{clean_path}",
        headers=_gh_headers(token, accept="application/vnd.github.raw+json"),
        params={"ref": ref},
    )
    if len(resp.content) > max_bytes:
        raise GitHubAppError("File exceeds viewer size limit")
    try:
        return resp.content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise GitHubAppError("Code file is not UTF-8 text") from exc


async def list_dir_at_ref(
    token: str,
    repo_full_name: str,
    path: str,
    ref: str,
) -> list[dict[str, Any]]:
    """List directory entries from GitHub Contents API at a pinned commit/ref."""
    clean_path = path.strip("/")
    endpoint = (
        f"{GITHUB_API_BASE}/repos/{repo_full_name}/contents/{clean_path}"
        if clean_path
        else f"{GITHUB_API_BASE}/repos/{repo_full_name}/contents"
    )
    resp = await _request_with_backoff(
        "GET",
        endpoint,
        headers=_gh_headers(token),
        params={"ref": ref},
    )
    data = resp.json()
    entries = data if isinstance(data, list) else ([data] if isinstance(data, dict) else [])
    return [
        {
            "name": str(entry.get("name") or ""),
            "path": str(entry.get("path") or ""),
            "type": "dir" if entry.get("type") == "dir" else "file",
            "size": entry.get("size"),
        }
        for entry in entries
        if isinstance(entry, dict) and entry.get("path")
    ]


async def fetch_repo_tree_at_ref(
    token: str,
    repo_full_name: str,
    ref: str,
    *,
    recursive: bool = True,
    max_entries: int = 5000,
) -> list[dict[str, Any]]:
    """Fetch repository tree entries via GitHub Git Trees API at ``ref``."""
    params = {"recursive": "1"} if recursive else None
    resp = await _request_with_backoff(
        "GET",
        f"{GITHUB_API_BASE}/repos/{repo_full_name}/git/trees/{ref}",
        headers=_gh_headers(token),
        params=params,
    )
    data = resp.json()
    raw_tree = data.get("tree") if isinstance(data, dict) else []
    if not isinstance(raw_tree, list):
        return []
    entries: list[dict[str, Any]] = []
    for item in raw_tree:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        item_path = item.get("path")
        if item_type not in ("blob", "tree") or not isinstance(item_path, str):
            continue
        entries.append(
            {
                "path": item_path,
                "name": item_path.rsplit("/", 1)[-1],
                "type": "dir" if item_type == "tree" else "file",
                "size": item.get("size"),
            }
        )
        if len(entries) >= max_entries:
            break
    return entries


def _safe_extract_tarball(archive_bytes: bytes, dest_dir: Path) -> None:
    """Extract a GitHub tarball into ``dest_dir``, stripping the top-level prefix.

    Rejects path traversal (``..``), absolute paths, symlinks, and hardlinks.
    """
    dest_real = os.path.realpath(dest_dir)
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as tf:
        for member in tf.getmembers():
            if member.issym() or member.islnk() or member.ischr() or member.isblk() or member.isfifo():
                continue
            parts = Path(member.name).parts
            if len(parts) <= 1:
                continue
            rel_parts = parts[1:]
            if any(p in ("..", "") or p.startswith("/") for p in rel_parts):
                raise GitHubAppError("Unsafe path in repository tarball")
            target_path = os.path.realpath(os.path.join(dest_real, *rel_parts))
            if os.path.commonpath([dest_real, target_path]) != dest_real:
                raise GitHubAppError("Tarball member escapes destination directory")
            if member.isdir():
                os.makedirs(target_path, exist_ok=True)
                continue
            if not member.isfile():
                continue
            os.makedirs(os.path.dirname(target_path), exist_ok=True)
            src = tf.extractfile(member)
            if src is None:
                continue
            with src, open(target_path, "wb") as out:
                out.write(src.read())


async def download_repo_tarball(
    token: str,
    repo_full_name: str,
    ref: str,
    dest_dir: Path,
    *,
    max_bytes: int = 100 * 1024 * 1024,
) -> None:
    """Stream and safely extract ``repo_full_name`` at ``ref`` into ``dest_dir``."""
    url = f"{GITHUB_API_BASE}/repos/{repo_full_name}/tarball/{ref}"
    buf = bytearray()
    async with (
        httpx.AsyncClient(timeout=120.0, follow_redirects=True) as client,
        client.stream("GET", url, headers=_gh_headers(token)) as resp,
    ):
            resp.raise_for_status()
            async for chunk in resp.aiter_bytes(65536):
                buf.extend(chunk)
                if len(buf) > max_bytes:
                    raise GitHubAppError(
                        f"Repository archive exceeds {max_bytes // (1024 * 1024)} MB limit"
                    )
    _safe_extract_tarball(bytes(buf), dest_dir)
