"""GDPR compliance endpoints — data export and deletion."""

import datetime
import logging

import sentry_sdk
from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient
from fastapi import APIRouter, Depends, HTTPException, Request

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["gdpr"])


def register_gdpr_routes(app_router, get_tenant_id, verify_infrastructure_access, limiter, config):
    """Register all GDPR routes with injected auth dependencies."""

    @app_router.get("/api/user/export")
    async def export_user_data(request: Request, tenant_id: str = Depends(get_tenant_id)):
        """GDPR Compliance: Export all user data as JSON."""
        try:
            from langgraph.checkpoint.redis.aio import AsyncRedisSaver
            threads = await request.app.state.redis.smembers(f"tenant:{tenant_id}:threads")
            titles = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles")
            export_data = {"tenant_id": tenant_id, "export_date": datetime.datetime.now(datetime.UTC).isoformat(), "threads": []}
            async with AsyncRedisSaver.from_conn_string(get_config().redis_url) as memory:
                for t in threads:
                    tid = t.decode("utf-8")
                    title = titles.get(t, b"").decode("utf-8")
                    state = await memory.aget_tuple({"configurable": {"thread_id": tid}})
                    messages = []
                    if state:
                        raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
                        for m in raw_messages:
                            messages.append({"type": m.__class__.__name__, "content": m.content})
                    export_data["threads"].append({"thread_id": tid, "title": title, "messages": messages})
            return export_data
        except Exception as e:  # noqa: BLE001
            logger.error("ERROR IN EXPORT_USER_DATA: %s", repr(e))
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail="Failed to export data")

    @app_router.delete("/api/user/data")
    async def delete_user_data(request: Request, tenant_id: str = Depends(get_tenant_id)):
        """GDPR Compliance: Delete all user data."""
        try:
            # 1. Delete from Neo4j
            neo4j_client = Neo4jStorageClient()
            try:
                neo4j_client._driver.execute_query("MATCH (n) WHERE n.tenant_id = $tenant_id DETACH DELETE n", {"tenant_id": tenant_id})
            except Exception as e:  # noqa: BLE001
                logger.error(f"Error deleting Neo4j data: {e}")
            # 2. Delete from Qdrant
            qdrant_client = QdrantStorageClient()
            try:
                from qdrant_client.http import models as rest
                qdrant_client.client.delete(
                    collection_name=qdrant_client.collection_name,
                    points_selector=rest.FilterSelector(filter=rest.Filter(must=[rest.FieldCondition(key="tenant_id", match=rest.MatchValue(value=tenant_id))]))
                )
            except Exception as e:  # noqa: BLE001
                logger.error(f"Error deleting Qdrant data: {e}")
            # 3. Delete from Redis & Postgres (Chat History)
            threads = await request.app.state.redis.smembers(f"tenant:{tenant_id}:threads")
            try:
                import psycopg
                async with await psycopg.AsyncConnection.connect(get_config().postgres_url) as conn:
                    for thread_id in threads:
                        tid = thread_id.decode() if isinstance(thread_id, bytes) else thread_id
                        await conn.execute("DELETE FROM checkpoints WHERE thread_id = %s", (tid,))
                        await conn.execute("DELETE FROM checkpoint_writes WHERE thread_id = %s", (tid,))
                        await conn.execute("DELETE FROM checkpoint_blobs WHERE thread_id = %s", (tid,))
                    await conn.commit()
            except Exception as e:  # noqa: BLE001
                logger.error(f"Error deleting Postgres chat history: {e}")
            await request.app.state.redis.delete(f"tenant:{tenant_id}:threads")
            await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_titles")
            await request.app.state.redis.delete(f"tenant:{tenant_id}:pinned_threads")
            await request.app.state.redis.delete(f"tenant:{tenant_id}:archived_threads")
            await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_projects")
            await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_timestamps")
            return {"status": "success", "message": "All user data deleted"}
        except Exception as e:  # noqa: BLE001
            logger.error("ERROR IN DELETE_USER_DATA: %s", repr(e))
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail="Failed to delete data")
