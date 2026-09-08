"""Personal API Key management endpoints."""

import logging

import sentry_sdk
from backend.security.api_keys import generate_api_key
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/user", tags=["api_keys"])


class ApiKeyCreateRequest(BaseModel):
    name: str
    expires_at: str | None = None  # ISO-8601 string; None = permanent


def register_api_key_routes(app_router, get_tenant_id, _get_supabase):
    """Register all API key routes with injected auth dependencies."""

    @app_router.get("/api/user/api-keys")
    async def list_api_keys(tenant_id: str = Depends(get_tenant_id)):
        """List all API keys for the current tenant (names, prefixes, dates — never hashes)."""
        try:
            response = (
                _get_supabase()
                .table("api_keys")
                .select("id, name, key_prefix, is_active, created_at, last_used_at, expires_at")
                .eq("tenant_id", tenant_id)
                .eq("is_active", True)
                .order("created_at", desc=True)
                .execute()
            )
            return {"api_keys": response.data or []}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error listing API keys for tenant {tenant_id}: {e}")
            raise HTTPException(status_code=500, detail="Failed to list API keys")

    @app_router.post("/api/user/api-keys", status_code=201)
    async def create_api_key_endpoint(payload: ApiKeyCreateRequest, tenant_id: str = Depends(get_tenant_id)):
        """Generate a new personal API key. Returns the raw key ONCE — it cannot be retrieved again."""
        raw_key, key_hash = generate_api_key()
        key_prefix = raw_key[:10]
        insert_data = {"tenant_id": tenant_id, "name": payload.name, "key_hash": key_hash, "key_prefix": key_prefix, "expires_at": payload.expires_at}
        try:
            response = _get_supabase().table("api_keys").insert(insert_data).execute()
            key_id = response.data[0]["id"]
            logger.info(f"New API key created for tenant {tenant_id}: {key_prefix}…")
            return {"id": key_id, "name": payload.name, "key": raw_key, "key_prefix": key_prefix, "created_at": response.data[0]["created_at"]}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error creating API key for tenant {tenant_id}: {e}")
            raise HTTPException(status_code=500, detail="Failed to create API key")

    @app_router.delete("/api/user/api-keys/{key_id}")
    async def revoke_api_key(key_id: str, tenant_id: str = Depends(get_tenant_id)):
        """Revoke (soft-delete) an API key. The key is immediately invalid."""
        try:
            result = (
                _get_supabase()
                .table("api_keys")
                .update({"is_active": False})
                .eq("id", key_id)
                .eq("tenant_id", tenant_id)
                .execute()
            )
            if not result.data:
                raise HTTPException(status_code=404, detail="API key not found")
            logger.info(f"API key {key_id} revoked for tenant {tenant_id}")
            return {"status": "revoked"}
        except HTTPException:
            raise
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error revoking API key {key_id}: {e}")
            raise HTTPException(status_code=500, detail="Failed to revoke API key")
