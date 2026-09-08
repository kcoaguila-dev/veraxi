"""MCP SSE transport endpoints — connects Host AI to the MCP server."""

import logging

from backend.mcp_server.context import tenant_context
from backend.mcp_server.server import mcp_server
from fastapi import Depends, Request
from mcp.server.sse import SseServerTransport

logger = logging.getLogger(__name__)

sse = SseServerTransport("/messages")


def register_mcp_transport_routes(app_router, get_tenant_id, verify_infrastructure_access, limiter, config):
    """Register MCP SSE transport routes."""

    @app_router.get("/sse")
    @limiter.limit(config.rate_limit_sse)
    async def handle_sse(request: Request, tenant_id: str = Depends(get_tenant_id)):
        """Host AI connects to this endpoint to open the SSE stream.
        The Bearer token defines the tenant_id, which is locked into ContextVars."""
        logger.info(f"Opening MCP SSE stream for tenant: {tenant_id}")
        tenant_context.set(tenant_id)
        async with sse.connect_sse(request.scope, request.receive, request._send) as (read_stream, write_stream):
            await mcp_server.run(read_stream, write_stream, mcp_server.create_initialization_options())

    @app_router.post("/messages")
    async def handle_messages(request: Request, tenant_id: str = Depends(get_tenant_id)):
        """Host AI posts JSON-RPC messages here. They are routed to the active SSE stream."""
        tenant_context.set(tenant_id)
        await sse.handle_post_message(request.scope, request.receive, request._send)
