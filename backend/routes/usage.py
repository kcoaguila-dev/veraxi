"""Usage / cost-estimate endpoints (Evidence-First Phase 5).

Currently a single pre-flight estimate for Deep (multi-agent debate)
mode, following the ``routes/sandboxes.py`` registration pattern. The
estimate is derived from the debate workflow's configured limits (see
:func:`backend.mcp_server.formatter.estimate_deep_usage`) and is
labelled as an estimate range — never a promise. Cost is only present
when the operator has filled in per-model pricing in
``backend/models_config.py``; otherwise it is null.
"""

import logging

from fastapi import Depends
from pydantic import BaseModel

from backend.mcp_server.formatter import estimate_deep_usage

logger = logging.getLogger(__name__)


class DeepEstimateRequest(BaseModel):
    model: str | None = None


def register_usage_routes(app_router, get_tenant_id, _get_supabase=None, config=None):
    """Register usage-estimate routes with injected auth dependencies."""

    @app_router.post("/api/chat/estimate-deep")
    async def estimate_deep(
        payload: DeepEstimateRequest | None = None,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Return a token-range (and cost, if priced) estimate for Deep mode."""
        model = payload.model if payload else None
        return estimate_deep_usage(model_name=model)
