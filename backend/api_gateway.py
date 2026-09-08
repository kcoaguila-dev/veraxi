"""Veraxi API Gateway — app factory, auth, middleware, and router registration.

This module is the FastAPI entrypoint. All endpoint logic lives in
``backend.routes.*`` sub-modules; this file wires them together and
provides shared auth dependencies.
"""

import logging
import sys
from contextlib import asynccontextmanager

import jwt
import sentry_sdk
from arq import create_pool
from arq.connections import RedisSettings
from backend import context as byod_context
from backend.config import get_config
from backend.mcp_server.llm_loop import (
    answer_question,
    generate_chat_title,
    stream_answer_question,
)
from backend.models_config import DEFAULT_PROVIDER_MODELS
from backend.security.api_keys import resolve_api_key
from backend.security.moderation import moderate_text
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from supabase import Client, create_client

# ---------------------------------------------------------------------------
# Logging & Sentry
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

from sentry_sdk.integrations.fastapi import FastApiIntegration

config = get_config()
if config.sentry_dsn:
    sentry_sdk.init(
        dsn=config.sentry_dsn,
        traces_sample_rate=1.0,
        profiles_sample_rate=1.0,
        integrations=[FastApiIntegration()],
    )

# ---------------------------------------------------------------------------
# JWKS (Supabase JWT validation)
# ---------------------------------------------------------------------------
jwks_url = f"{config.supabase_url}/auth/v1/.well-known/jwks.json"
jwks_client = PyJWKClient(jwks_url)

# ---------------------------------------------------------------------------
# Lifespan — Redis pool
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    config = get_config()
    app.state.redis = await create_pool(RedisSettings.from_dsn(config.redis_url))
    yield
    await app.state.redis.close()


app = FastAPI(
    title="Veraxi Intelligence Engine",
    description="Sovereign Hybrid GraphRAG & MCP Intelligence Platform",
    version="1.0.0",
    lifespan=lifespan,
)

# ---------------------------------------------------------------------------
# Rate Limiter
# ---------------------------------------------------------------------------

def get_auth_token_key(request: Request) -> str:
    auth = request.headers.get("Authorization")
    if auth and auth.startswith("Bearer "):
        return auth[7:]
    return get_remote_address(request)


test_storage = "memory://" if "pytest" in sys.modules else config.redis_url
limiter = Limiter(key_func=get_auth_token_key, storage_uri=test_storage)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# ---------------------------------------------------------------------------
# CORS
# ---------------------------------------------------------------------------
app.add_middleware(
    CORSMiddleware,
    allow_origins=config.cors_origins.split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# BYOD Context Middleware
# ---------------------------------------------------------------------------

@app.middleware("http")
async def byod_context_middleware(request: Request, call_next):
    # Extract BYOD headers and set them in ContextVars for this request
    byod_context.request_neo4j_uri.set(request.headers.get("x-byod-neo4j-uri"))
    byod_context.request_neo4j_user.set(request.headers.get("x-byod-neo4j-user"))
    byod_context.request_neo4j_pass.set(request.headers.get("x-byod-neo4j-pass"))
    byod_context.request_qdrant_url.set(request.headers.get("x-byod-qdrant-url"))
    byod_context.request_qdrant_key.set(request.headers.get("x-byod-qdrant-key"))
    response = await call_next(request)
    return response


# ---------------------------------------------------------------------------
# Auth Dependencies (shared across routers)
# ---------------------------------------------------------------------------
security = HTTPBearer(auto_error=False)


def _get_jwt_payload(token: str) -> dict:
    try:
        signing_key = jwks_client.get_signing_key_from_jwt(token)
        return jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256", "ES256", "HS256"],
            audience="authenticated",
        )
    except jwt.ExpiredSignatureError as e:
        logger.warning(f"JWT Expired: {e}")
        raise HTTPException(status_code=401, detail="Token has expired")
    except jwt.InvalidAudienceError as e:
        logger.warning(f"JWT Invalid Audience: {e}")
        raise HTTPException(status_code=401, detail="Invalid audience. Expected 'authenticated'.")
    except jwt.InvalidTokenError as e:
        logger.warning(f"JWT Validation Error: {e}")
        raise HTTPException(status_code=401, detail="Invalid token")


def _decode_and_validate_jwt(token: str) -> str:
    payload = _get_jwt_payload(token)
    tenant_id = payload.get("sub")
    if not tenant_id:
        raise HTTPException(status_code=401, detail="Invalid token: missing sub (user ID) claim")
    return tenant_id


# Lazy Supabase service-role client — used for API key lookups.
_supabase_client: "Client | None" = None


def _get_supabase() -> "Client":
    """Return a cached Supabase service-role client."""
    global _supabase_client
    if _supabase_client is None:
        _supabase_client = create_client(config.supabase_url, config.supabase_service_key)
    return _supabase_client


def get_tenant_id(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(security),  # noqa: B008
) -> str:
    if not config.auth_enabled:
        header_tenant = request.headers.get("x-tenant-id")
        if header_tenant:
            return header_tenant
        return "local_personal_user"
    if not credentials:
        logger.warning("No credentials provided in request headers (Authorization header missing or invalid)")
        raise HTTPException(status_code=401, detail="Not authenticated")
    token = credentials.credentials
    if token.startswith("vx-"):
        return resolve_api_key(token, _get_supabase())
    return _decode_and_validate_jwt(token)


async def verify_infrastructure_access(
    request: Request,
    tenant_id: str = Depends(get_tenant_id),
) -> str:
    if not config.is_enterprise or not config.auth_enabled:
        return tenant_id
    uri = byod_context.request_neo4j_uri.get()
    qdrant = byod_context.request_qdrant_url.get()
    if uri and qdrant:
        return tenant_id
    cache_key = f"tenant:{tenant_id}:subscription_status"
    cached = await request.app.state.redis.get(cache_key)
    if cached is not None:
        is_subscribed = cached.decode("utf-8") == "true"
    else:
        import asyncio
        def _fetch_sub():
            try:
                res = _get_supabase().table("users").select("is_subscribed").eq("id", tenant_id).execute()
                if res.data and len(res.data) > 0:
                    return bool(res.data[0].get("is_subscribed", False))
            except Exception as e:  # noqa: BLE001
                logger.error(f"Failed to check subscription status: {e}")
            return False
        is_subscribed = await asyncio.to_thread(_fetch_sub)
        await request.app.state.redis.setex(cache_key, 86400, "true" if is_subscribed else "false")
    if is_subscribed:
        return tenant_id
    raise HTTPException(
        status_code=402,
        detail="Payment Required: Free tier users must configure Bring Your Own Database (BYOD) infrastructure in Settings.",
    )


# ---------------------------------------------------------------------------
# Register all route modules
# ---------------------------------------------------------------------------
from backend.routes.admin import register_admin_routes
from backend.routes.api_keys import register_api_key_routes
from backend.routes.chat import register_chat_routes
from backend.routes.files import register_file_routes
from backend.routes.gdpr import register_gdpr_routes
from backend.routes.ingestion import register_ingestion_routes
from backend.routes.mcp_transport import register_mcp_transport_routes
from backend.routes.payments import register_payment_routes
from backend.routes.projects import register_project_routes
from backend.routes.tts import register_tts_routes

register_chat_routes(app, get_tenant_id, verify_infrastructure_access, limiter, config)
register_ingestion_routes(app, get_tenant_id, verify_infrastructure_access, limiter, config)
register_tts_routes(app, get_tenant_id, verify_infrastructure_access, limiter, config)
register_payment_routes(app, get_tenant_id, verify_infrastructure_access, limiter, config)
register_admin_routes(app, get_tenant_id, verify_infrastructure_access, limiter, config)
register_project_routes(app, get_tenant_id, verify_infrastructure_access, limiter, config)
register_file_routes(app, get_tenant_id, verify_infrastructure_access, limiter, config)
register_api_key_routes(app, get_tenant_id, _get_supabase)
register_gdpr_routes(app, get_tenant_id, verify_infrastructure_access, limiter, config)
register_mcp_transport_routes(app, get_tenant_id, verify_infrastructure_access, limiter, config)


# ---------------------------------------------------------------------------
# Backward-compatible re-exports for existing tests.
# Tests import e.g. ``from backend.api_gateway import app, get_tenant_id``
# and patch ``backend.api_gateway.moderate_text``.  These re-exports keep
# those paths working without requiring test modifications.
# ---------------------------------------------------------------------------
from backend.routes.ingestion import _ensure_schema_exists
from backend.storage.quota import check_tenant_hard_cap

__all__ = [
    "DEFAULT_PROVIDER_MODELS",
    "Neo4jStorageClient",
    "QdrantStorageClient",
    "_ensure_schema_exists",
    "answer_question",
    "app",
    "check_tenant_hard_cap",
    "config",
    "generate_chat_title",
    "get_tenant_id",
    "limiter",
    "moderate_text",
    "stream_answer_question",
    "verify_infrastructure_access",
]
