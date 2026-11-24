"""External ACP Agent Runtime routes (status, permission gate, cancel, close)."""

from __future__ import annotations

from typing import Literal

from fastapi import Depends, HTTPException
from pydantic import BaseModel

from backend.acp.broker import get_acp_broker


class AcpPermissionRequest(BaseModel):
    request_id: str
    outcome: Literal["allow_once", "allow_session", "deny"] = "deny"


def register_acp_routes(app_router, get_tenant_id, _get_supabase=None, config=None):
    """Register ACP runtime control routes with injected auth dependencies."""

    @app_router.get("/api/acp/status")
    async def acp_status(tenant_id: str = Depends(get_tenant_id)):
        """Return ACP transport availability and read-only local usage summary."""
        return get_acp_broker().get_status(tenant_id)

    @app_router.post("/api/acp/sessions/{session_id}/permission")
    async def acp_resolve_permission(
        session_id: str,
        payload: AcpPermissionRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Resolve an interactive ``session/request_permission`` prompt."""
        ok = await get_acp_broker().resolve_permission(
            tenant_id=tenant_id,
            session_id=session_id,
            request_id=payload.request_id,
            outcome=payload.outcome,
        )
        if not ok:
            raise HTTPException(
                status_code=404,
                detail="ACP permission request not found or already resolved.",
            )
        return {"resolved": True, "outcome": payload.outcome}

    @app_router.post("/api/acp/sessions/{session_id}/cancel")
    async def acp_cancel_turn(
        session_id: str,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Cancel an in-flight ACP prompt turn."""
        cancelled = await get_acp_broker().cancel_session(
            tenant_id=tenant_id,
            session_id=session_id,
        )
        return {"cancelled": cancelled}

    @app_router.delete("/api/acp/sessions/{session_id}")
    async def acp_close_session(
        session_id: str,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Terminate an ACP session subprocess."""
        del tenant_id
        await get_acp_broker().close_session(session_id)
        return {"closed": True}
