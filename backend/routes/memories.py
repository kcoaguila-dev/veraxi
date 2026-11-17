"""User-visible memory endpoints (Evidence-First Phase 5).

Follows the ``routes/sandboxes.py`` registration pattern: routes are
registered with the gateway's injected ``get_tenant_id`` dependency
and reach Supabase through ``_get_supabase``. When Supabase is
unavailable (stateless local mode) the endpoints return 501.

User identity: this codebase has no separate user-id dependency —
``get_tenant_id`` returns the authenticated user's id (the same value
RLS policies compare against ``auth.uid()``), so it scopes both the
``tenant_id`` and ``user_id`` columns, exactly as the sandbox and
integration routes scope by tenant alone.
"""

import asyncio
import logging

from fastapi import Depends, HTTPException
from pydantic import BaseModel

from backend.services import memory_store as store

logger = logging.getLogger(__name__)


def _require_supabase(_get_supabase):
    sb = _get_supabase()
    if not sb:
        raise HTTPException(
            status_code=501,
            detail="Memories are not supported in stateless local mode",
        )
    return sb


class MemoryCreateRequest(BaseModel):
    content: str
    source: str = "manual"
    valid_from: str | None = None


class MemoryUpdateRequest(BaseModel):
    content: str | None = None
    source: str | None = None
    valid_from: str | None = None
    valid_to: str | None = None


def register_memory_routes(app_router, get_tenant_id, _get_supabase, config=None):
    """Register all user-memory routes with injected auth dependencies."""

    @app_router.get("/api/v1/memories")
    async def list_memories(
        include_expired: bool = True,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """List the user's memories (newest first)."""
        sb = _require_supabase(_get_supabase)
        try:
            rows = await asyncio.to_thread(
                store.list_memories,
                sb,
                tenant_id,
                tenant_id,
                include_expired=include_expired,
            )
            return {"memories": [store.public_view(row) for row in rows]}
        except Exception as e:
            store.report_error(e)
            raise HTTPException(status_code=500, detail="Failed to list memories") from e

    @app_router.post("/api/v1/memories", status_code=201)
    async def create_memory(
        payload: MemoryCreateRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Create a memory for the user."""
        sb = _require_supabase(_get_supabase)
        try:
            row = await asyncio.to_thread(
                store.create_memory,
                sb,
                tenant_id,
                tenant_id,
                payload.content,
                payload.source,
                payload.valid_from,
            )
            return store.public_view(row)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        except Exception as e:
            store.report_error(e)
            raise HTTPException(status_code=500, detail="Failed to create memory") from e

    @app_router.get("/api/v1/memories/{memory_id}")
    async def get_memory(memory_id: str, tenant_id: str = Depends(get_tenant_id)):
        """Return one of the user's memories."""
        sb = _require_supabase(_get_supabase)
        row = await asyncio.to_thread(
            store.get_memory, sb, tenant_id, tenant_id, memory_id
        )
        if row is None:
            raise HTTPException(status_code=404, detail="Memory not found")
        return store.public_view(row)

    @app_router.put("/api/v1/memories/{memory_id}")
    async def update_memory(
        memory_id: str,
        payload: MemoryUpdateRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Update a memory's content/source/validity."""
        sb = _require_supabase(_get_supabase)
        try:
            row = await asyncio.to_thread(
                store.update_memory,
                sb,
                tenant_id,
                tenant_id,
                memory_id,
                payload.model_dump(exclude_none=True),
            )
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        except Exception as e:
            store.report_error(e)
            raise HTTPException(status_code=500, detail="Failed to update memory") from e
        if row is None:
            raise HTTPException(status_code=404, detail="Memory not found")
        return store.public_view(row)

    @app_router.post("/api/v1/memories/{memory_id}/expire")
    async def expire_memory(memory_id: str, tenant_id: str = Depends(get_tenant_id)):
        """Soft-expire a memory (sets valid_to; the row is kept)."""
        sb = _require_supabase(_get_supabase)
        try:
            row = await asyncio.to_thread(
                store.expire_memory, sb, tenant_id, tenant_id, memory_id
            )
        except Exception as e:
            store.report_error(e)
            raise HTTPException(status_code=500, detail="Failed to expire memory") from e
        if row is None:
            raise HTTPException(status_code=404, detail="Memory not found")
        return store.public_view(row)

    @app_router.delete("/api/v1/memories/{memory_id}")
    async def delete_memory(memory_id: str, tenant_id: str = Depends(get_tenant_id)):
        """Hard-delete one of the user's memories."""
        sb = _require_supabase(_get_supabase)
        try:
            removed = await asyncio.to_thread(
                store.delete_memory, sb, tenant_id, tenant_id, memory_id
            )
        except Exception as e:
            store.report_error(e)
            raise HTTPException(status_code=500, detail="Failed to delete memory") from e
        if not removed:
            raise HTTPException(status_code=404, detail="Memory not found")
        return {"status": "deleted", "id": memory_id}
