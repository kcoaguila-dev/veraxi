"""MCP transport endpoints — connects Host AI to the MCP server via SSE or Streamable HTTP."""

import logging

from fastapi import Depends, Request
from mcp.server.sse import SseServerTransport
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from starlette.responses import Response

from backend.mcp_server.context import tenant_context
from backend.mcp_server.server import mcp_server

logger = logging.getLogger(__name__)

sse = SseServerTransport("/messages")


class _NoOpResponse(Response):
    """Empty response sentinel when the underlying ASGI handler has already written response."""

    async def __call__(self, scope, receive, send):
        pass


def register_mcp_transport_routes(
    app_router, get_tenant_id, verify_infrastructure_access, limiter, config
):
    """Register MCP transport routes (SSE and Stateless Streamable HTTP)."""

    @app_router.api_route("/mcp", methods=["GET", "POST", "DELETE"])
    @limiter.limit(config.rate_limit_sse)
    async def handle_streamable_mcp(
        request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        """Stateless MCP Streamable HTTP endpoint.
        Eliminates session 404s on multi-worker / Cloud Run serverless deployments.
        """
        logger.debug(
            f"Handling stateless MCP Streamable HTTP request for tenant: {tenant_id}"
        )
        tenant_context.set(tenant_id)

        session_manager = StreamableHTTPSessionManager(
            app=mcp_server._lowlevel_server,
            stateless=True,
            json_response=True,
        )
        async with session_manager.run():
            await session_manager.handle_request(
                request.scope, request.receive, request._send
            )
        return _NoOpResponse()

    @app_router.get("/sse")
    @limiter.limit(config.rate_limit_sse)
    async def handle_sse(request: Request, tenant_id: str = Depends(get_tenant_id)):
        """Host AI connects to this endpoint to open the SSE stream.
        The Bearer token defines the tenant_id, which is locked into ContextVars."""
        logger.info(f"Opening MCP SSE stream for tenant: {tenant_id}")
        tenant_context.set(tenant_id)

        async with sse.connect_sse(request.scope, request.receive, request._send) as (
            read_stream,
            write_stream,
        ):
            await mcp_server._lowlevel_server.run(
                read_stream,
                write_stream,
                mcp_server._lowlevel_server.create_initialization_options(),
            )

    class _SsePostMessageHandler:
        """Pure ASGI handler for MCP SSE message posts.
        Directly attached via add_route on both unslashed (/messages) and slashed (/messages/)
        to eliminate 307 redirects and protocol downgrade behind reverse proxies.
        """

        async def __call__(self, scope, receive, send):
            if scope["type"] == "http":
                try:
                    headers = dict(scope.get("headers", []))

                    def _get_h(k: bytes) -> str | None:
                        v = headers.get(k)
                        return v.decode("latin-1") if v else None

                    auth = _get_h(b"authorization")
                    tenant_id = None
                    if auth and auth.startswith("Bearer "):
                        from fastapi.security import HTTPAuthorizationCredentials

                        creds = HTTPAuthorizationCredentials(
                            scheme="Bearer", credentials=auth[7:]
                        )
                        dummy_req = Request(scope)
                        tenant_id = get_tenant_id(dummy_req, creds)
                    elif _get_h(b"x-tenant-id"):
                        tenant_id = _get_h(b"x-tenant-id")

                    if tenant_id:
                        tenant_context.set(tenant_id)
                except Exception as e:
                    logger.debug(f"Could not extract tenant for /messages: {e}")

            await sse.handle_post_message(scope, receive, send)

    sse_handler = _SsePostMessageHandler()
    app_router.add_route("/messages", sse_handler, methods=["POST", "OPTIONS"])
    app_router.add_route("/messages/", sse_handler, methods=["POST", "OPTIONS"])
