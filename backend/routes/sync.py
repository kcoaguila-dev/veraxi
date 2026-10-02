import logging
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from supabase import Client

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["sync"])

class SyncPutRequest(BaseModel):
    encrypted_blob: str
    salt: str

def register_sync_routes(app_router, get_tenant_id, get_supabase, config):
    @app_router.get("/api/sync/byod")
    async def get_byod_sync(tenant_id: str = Depends(get_tenant_id)):
        sb: Client = get_supabase()

        # 1. Check premium status
        user_res = sb.table("users").select("is_subscribed").eq("id", tenant_id).execute()
        if not user_res.data or not user_res.data[0].get("is_subscribed"):
            raise HTTPException(status_code=403, detail="Sync is a premium feature.")

        # 2. Fetch sync data
        res = sb.table("user_sync_data").select("encrypted_blob,salt").eq("tenant_id", tenant_id).execute()
        if not res.data:
            raise HTTPException(status_code=404, detail="No sync data found.")

        return {
            "encrypted_blob": res.data[0]["encrypted_blob"],
            "salt": res.data[0]["salt"]
        }

    @app_router.put("/api/sync/byod")
    async def put_byod_sync(request: SyncPutRequest, tenant_id: str = Depends(get_tenant_id)):
        sb: Client = get_supabase()

        # 1. Check premium status
        user_res = sb.table("users").select("is_subscribed").eq("id", tenant_id).execute()
        if not user_res.data or not user_res.data[0].get("is_subscribed"):
            raise HTTPException(status_code=403, detail="Sync is a premium feature.")

        # 2. Upsert sync data
        sb.table("user_sync_data").upsert({
            "tenant_id": tenant_id,
            "encrypted_blob": request.encrypted_blob,
            "salt": request.salt,
            "updated_at": "now()"
        }).execute()

        return {"status": "success"}
