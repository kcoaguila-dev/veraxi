import logging

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from supabase import Client

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["sync"])


class SyncPutRequest(BaseModel):
    encrypted_blob: str
    salt: str


def _require_supabase(get_supabase) -> Client:
    """Return a live Supabase client or raise 503.

    Centralises the None-guard so individual handlers stay flat.
    """
    sb = get_supabase()
    if sb is None:
        raise HTTPException(
            status_code=503,
            detail="Sync service is unavailable: Supabase is not configured.",
        )
    return sb


def _require_premium(sb: Client, tenant_id: str) -> None:
    """Raise 403 if the tenant does not have an active subscription.

    Extracted here to keep each route handler at a single indentation
    level (guard-clause pattern, zero-cognitive-complexity policy).
    """
    user_res = sb.table("users").select("is_subscribed").eq("id", tenant_id).execute()
    if not user_res.data or not user_res.data[0].get("is_subscribed"):  # type: ignore
        raise HTTPException(status_code=403, detail="Sync is a premium feature.")


def register_sync_routes(app_router, get_tenant_id, get_supabase, config):
    @app_router.get("/api/sync/byod")
    async def get_byod_sync(tenant_id: str = Depends(get_tenant_id)):
        sb = _require_supabase(get_supabase)

        # 1. Check premium status
        _require_premium(sb, tenant_id)

        # 2. Fetch sync data
        res = (
            sb.table("user_sync_data")
            .select("encrypted_blob,salt")
            .eq("tenant_id", tenant_id)
            .execute()
        )
        if not res.data:
            raise HTTPException(status_code=404, detail="No sync data found.")

        data_list = res.data
        if not isinstance(data_list, list) or len(data_list) == 0:
            raise HTTPException(status_code=404, detail="No sync data found.")
        first_item = data_list[0]
        if not isinstance(first_item, dict):
            raise HTTPException(status_code=500, detail="Invalid sync data format.")
        return {
            "encrypted_blob": first_item.get("encrypted_blob"),
            "salt": first_item.get("salt"),
        }

    @app_router.put("/api/sync/byod")
    async def put_byod_sync(
        request: SyncPutRequest, tenant_id: str = Depends(get_tenant_id)
    ):
        sb = _require_supabase(get_supabase)

        # 1. Check premium status
        _require_premium(sb, tenant_id)

        # 2. Upsert sync data
        sb.table("user_sync_data").upsert(
            {
                "tenant_id": tenant_id,
                "encrypted_blob": request.encrypted_blob,
                "salt": request.salt,
                "updated_at": "now()",
            }
        ).execute()

        return {"status": "success"}
