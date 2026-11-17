"""Generic OAuth 2.0 (PKCE) engine for 1-click connectors.

GitHub is the only live provider; the registry is structured so
``google_drive``, ``notion``, ``linear``, and ``slack`` can be enabled
later by filling in endpoints and credentials — their entries exist
with ``enabled=False`` and starting a flow for them fails cleanly.

Flow:

- :func:`build_authorize_url` mints a random ``state`` and a PKCE
  ``code_verifier``/``code_challenge`` (S256), storing
  ``{tenant_id, provider, verifier}`` in Redis under the state for 10
  minutes (the same Redis the gateway publishes on ``app.state``).
- :func:`handle_callback` validates and consumes the state, exchanges
  the code at the provider token endpoint, and stores the tokens
  encrypted in ``tenant_integrations`` via the integration store.
- :func:`get_valid_access_token` returns a usable access token,
  transparently refreshing under a Redis lock when the stored token is
  expired and a refresh token exists.

Tokens are never logged and never leave the backend.
"""

import base64
import hashlib
import json
import logging
import secrets as stdlib_secrets
from datetime import UTC, datetime, timedelta

import httpx
import sentry_sdk

from backend.services import integration_store as store

logger = logging.getLogger(__name__)

STATE_TTL_SECONDS = 600
_REFRESH_LOCK_TTL = 30


def _provider_registry(config) -> dict:
    """Provider definitions; only GitHub is enabled (credentials permitting)."""
    return {
        "github": {
            "enabled": True,
            "display_name": "GitHub",
            "authorize_url": "https://github.com/login/oauth/authorize",
            "token_url": "https://github.com/login/oauth/access_token",
            "client_id": config.github_client_id if config else "",
            "client_secret": config.github_client_secret if config else "",
            "default_scopes": ["repo", "read:user"],
            "slug": "github",
            "kind": "oauth",
        },
        "google_drive": {
            "enabled": False,
            "display_name": "Google Drive",
            "authorize_url": "https://accounts.google.com/o/oauth2/v2/auth",
            "token_url": "https://oauth2.googleapis.com/token",
            "client_id": "",
            "client_secret": "",
            "default_scopes": ["https://www.googleapis.com/auth/drive.readonly"],
            "slug": "google-drive",
            "kind": "oauth",
        },
        "notion": {
            "enabled": False,
            "display_name": "Notion",
            "authorize_url": "https://api.notion.com/v1/oauth/authorize",
            "token_url": "https://api.notion.com/v1/oauth/token",
            "client_id": "",
            "client_secret": "",
            "default_scopes": [],
            "slug": "notion",
            "kind": "oauth",
        },
        "linear": {
            "enabled": False,
            "display_name": "Linear",
            "authorize_url": "https://linear.app/oauth/authorize",
            "token_url": "https://api.linear.app/oauth/token",
            "client_id": "",
            "client_secret": "",
            "default_scopes": ["read"],
            "slug": "linear",
            "kind": "oauth",
        },
        "slack": {
            "enabled": False,
            "display_name": "Slack",
            "authorize_url": "https://slack.com/oauth/v2/authorize",
            "token_url": "https://slack.com/api/oauth.v2.access",
            "client_id": "",
            "client_secret": "",
            "default_scopes": [],
            "slug": "slack",
            "kind": "oauth",
        },
    }


def get_provider(config, provider: str) -> dict:
    registry = _provider_registry(config)
    if provider not in registry:
        raise ValueError(f"Unknown OAuth provider: {provider}")
    return registry[provider]


def list_providers(config) -> list[dict]:
    """Catalog entries for the settings UI (no secrets)."""
    out = []
    for key, prov in _provider_registry(config).items():
        out.append(
            {
                "provider": key,
                "display_name": prov["display_name"],
                "enabled": bool(prov["enabled"] and prov["client_id"]),
                "configured": bool(prov["client_id"]),
            }
        )
    return out


def redirect_uri(config, provider: str) -> str:
    base = (config.oauth_redirect_base_url if config else "") or (
        config.public_app_url if config else ""
    )
    return f"{base.rstrip('/')}/api/integrations/oauth/{provider}/callback"


def _state_key(state: str) -> str:
    return f"oauth:state:{state}"


def _pkce_pair() -> tuple[str, str]:
    verifier = stdlib_secrets.token_urlsafe(48)
    digest = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).decode().rstrip("=")
    return verifier, challenge


async def build_authorize_url(config, redis_client, provider: str, tenant_id: str) -> str:
    """Create state+PKCE, persist them in Redis, return the authorize URL."""
    prov = get_provider(config, provider)
    if not prov["enabled"]:
        raise ValueError(f"OAuth provider {provider} is not enabled yet")
    if not prov["client_id"]:
        raise ValueError(
            f"OAuth provider {provider} is not configured (missing client id)"
        )
    verifier, challenge = _pkce_pair()
    state = stdlib_secrets.token_urlsafe(32)
    payload = json.dumps(
        {"tenant_id": tenant_id, "provider": provider, "verifier": verifier}
    )
    await redis_client.setex(_state_key(state), STATE_TTL_SECONDS, payload)
    params = {
        "client_id": prov["client_id"],
        "redirect_uri": redirect_uri(config, provider),
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    if prov["default_scopes"]:
        params["scope"] = " ".join(prov["default_scopes"])
    request = httpx.Request("GET", prov["authorize_url"], params=params)
    return str(request.url)


async def _consume_state(redis_client, state: str, provider: str) -> dict:
    raw = await redis_client.get(_state_key(state))
    if raw is None:
        raise ValueError("OAuth state is invalid or has expired")
    await redis_client.delete(_state_key(state))
    if isinstance(raw, bytes):
        raw = raw.decode()
    data = json.loads(raw)
    if data.get("provider") != provider:
        raise ValueError("OAuth state does not match the provider")
    return data


async def _exchange_code(config, provider: str, code: str, verifier: str) -> dict:
    prov = get_provider(config, provider)
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            prov["token_url"],
            data={
                "client_id": prov["client_id"],
                "client_secret": prov["client_secret"],
                "code": code,
                "redirect_uri": redirect_uri(config, provider),
                "code_verifier": verifier,
                "grant_type": "authorization_code",
            },
            headers={"Accept": "application/json"},
        )
        response.raise_for_status()
        return response.json()


def _expires_at(token_payload: dict) -> str | None:
    expires_in = token_payload.get("expires_in")
    if not expires_in:
        return None
    return (datetime.now(UTC) + timedelta(seconds=int(expires_in))).isoformat()


def _store_tokens(sb, config, provider: str, tenant_id: str, token_payload: dict) -> dict:
    prov = get_provider(config, provider)
    secrets_payload = {"access_token": token_payload.get("access_token", "")}
    if token_payload.get("refresh_token"):
        secrets_payload["refresh_token"] = token_payload["refresh_token"]
    scopes = (token_payload.get("scope") or "").replace(",", " ").split()
    existing = store.get_integration_by_provider(sb, tenant_id, provider)
    if existing:
        return store.update_integration(
            sb,
            tenant_id,
            existing["id"],
            secrets=secrets_payload,
            scopes=scopes or existing.get("scopes") or [],
            token_expires_at=_expires_at(token_payload),
            status="connected",
            display_name=existing.get("display_name") or prov["display_name"],
        )
    return store.create_integration(
        sb,
        tenant_id,
        kind="oauth",
        provider=provider,
        slug=store.unique_slug(sb, tenant_id, prov["slug"]),
        display_name=prov["display_name"],
        config={},
        secrets=secrets_payload,
        scopes=scopes,
        token_expires_at=_expires_at(token_payload),
    )


async def handle_callback(config, redis_client, sb, provider: str, code: str, state: str) -> dict:
    """Validate state, exchange the code, and store encrypted tokens."""
    state_data = await _consume_state(redis_client, state, provider)
    token_payload = await _exchange_code(
        config, provider, code, state_data["verifier"]
    )
    if not token_payload.get("access_token"):
        err_code = token_payload.get("error") or "unknown_error"
        err_desc = token_payload.get("error_description") or ""
        logger.warning(
            "OAuth token exchange for %s failed: error=%s description=%s",
            provider,
            err_code,
            err_desc,
        )
        raise ValueError(f"Provider did not return an access token ({err_code})")
    return _store_tokens(sb, config, provider, state_data["tenant_id"], token_payload)


def _token_expired(row: dict) -> bool:
    expires_at = row.get("token_expires_at")
    if not expires_at:
        return False
    try:
        parsed = datetime.fromisoformat(str(expires_at))
    except ValueError:
        return False
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    # Refresh a minute early to avoid handing out a token that dies mid-call.
    return parsed <= datetime.now(UTC) + timedelta(seconds=60)


async def _refresh_tokens(config, provider: str, refresh_token: str) -> dict:
    prov = get_provider(config, provider)
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            prov["token_url"],
            data={
                "client_id": prov["client_id"],
                "client_secret": prov["client_secret"],
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
            headers={"Accept": "application/json"},
        )
        response.raise_for_status()
        return response.json()


async def get_valid_access_token(
    config, sb, tenant_id: str, provider: str, redis_client=None
) -> str:
    """Return a non-expired access token, refreshing under a lock if needed."""
    row = store.get_integration_by_provider(sb, tenant_id, provider)
    if not row:
        raise ValueError(f"No {provider} integration connected for this tenant")
    secrets_payload = store.decrypt_row_secrets(row)
    access_token = secrets_payload.get("access_token", "")
    if not _token_expired(row):
        return access_token
    refresh_token = secrets_payload.get("refresh_token")
    if not refresh_token:
        raise ValueError(f"The {provider} token has expired and cannot be refreshed")

    lock_key = f"oauth:refresh-lock:{tenant_id}:{provider}"
    lock_acquired = True
    if redis_client is not None:
        # nx semantics: real Redis honors it; the in-memory pool used in
        # local/stateless mode always grants (single-process anyway).
        lock_acquired = bool(
            await redis_client.set(lock_key, "1", nx=True, ex=_REFRESH_LOCK_TTL)
        )
    try:
        if lock_acquired:
            payload = await _refresh_tokens(config, provider, refresh_token)
            if not payload.get("access_token"):
                raise ValueError("Provider refresh did not return an access token")
            merged = {**secrets_payload}
            merged["access_token"] = payload["access_token"]
            if payload.get("refresh_token"):
                merged["refresh_token"] = payload["refresh_token"]
            store.update_integration(
                sb,
                tenant_id,
                row["id"],
                secrets=merged,
                token_expires_at=_expires_at(payload),
                status="connected",
            )
            return payload["access_token"]
        # Another worker is refreshing: re-read once and use its result.
        fresh = store.get_integration_by_provider(sb, tenant_id, provider)
        if fresh and not _token_expired(fresh):
            return store.decrypt_row_secrets(fresh).get("access_token", "")
        return access_token
    except Exception as e:
        sentry_sdk.capture_exception(e)
        raise
    finally:
        if redis_client is not None and lock_acquired:
            try:
                await redis_client.delete(lock_key)
            except Exception as e:  # Lock cleanup must not mask the result.
                sentry_sdk.capture_exception(e)
                logger.warning("Failed to release OAuth refresh lock: %s", e)
