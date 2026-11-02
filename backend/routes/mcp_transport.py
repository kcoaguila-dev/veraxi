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

_streamable_session_manager: StreamableHTTPSessionManager | None = None


def get_streamable_session_manager() -> StreamableHTTPSessionManager:
    """Return the active StreamableHTTPSessionManager singleton, creating one if needed."""
    global _streamable_session_manager
    if _streamable_session_manager is None:
        _streamable_session_manager = StreamableHTTPSessionManager(
            app=mcp_server._lowlevel_server,
            stateless=True,
            json_response=True,
        )
    return _streamable_session_manager


def reset_streamable_session_manager() -> StreamableHTTPSessionManager:
    """Instantiate a new StreamableHTTPSessionManager for server startup/lifespan."""
    global _streamable_session_manager
    _streamable_session_manager = StreamableHTTPSessionManager(
        app=mcp_server._lowlevel_server,
        stateless=True,
        json_response=True,
    )
    return _streamable_session_manager


class _StreamableHttpApp:
    """Pure ASGI handler for Stateless MCP Streamable HTTP endpoint.
    Eliminates session 404s and directly processes ASGI receive/send without FastAPI response wrapping.
    """

    def __init__(self, app_router, get_tenant_id):
        self.app_router = app_router
        self.get_tenant_id = get_tenant_id

    async def _resolve_tenant(self, scope, creds) -> str | None:
        dummy_req = Request(scope)
        resolve_fn = getattr(self.app_router, "dependency_overrides", {}).get(
            self.get_tenant_id, self.get_tenant_id
        )
        try:
            import inspect

            sig = inspect.signature(resolve_fn)
            if len(sig.parameters) == 0:
                res = resolve_fn()
            elif len(sig.parameters) == 1:
                res = resolve_fn(dummy_req)
            else:
                res = resolve_fn(dummy_req, creds)
            if inspect.iscoroutine(res):
                return await res
            return res
        except Exception as e:
            logger.debug(f"Tenant resolution error on /mcp: {e}")
            return None

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            if scope.get("method") == "OPTIONS":
                response = Response(status_code=204)
                await response(scope, receive, send)
                return

            headers = dict(scope.get("headers", []))

            def _get_h(k: bytes) -> str | None:
                v = headers.get(k)
                return v.decode("latin-1") if v else None

            tenant_id = None
            if _get_h(b"x-tenant-id"):
                tenant_id = _get_h(b"x-tenant-id")
            else:
                auth = _get_h(b"authorization")
                creds = None
                if auth and auth.startswith("Bearer "):
                    from fastapi.security import HTTPAuthorizationCredentials

                    creds = HTTPAuthorizationCredentials(
                        scheme="Bearer", credentials=auth[7:]
                    )
                tenant_id = await self._resolve_tenant(scope, creds)

            if not tenant_id:
                res = Response(
                    content='{"jsonrpc":"2.0","error":{"code":-32000,"message":"Unauthorized: Missing or invalid credentials"}}',
                    status_code=401,
                    media_type="application/json",
                )
                await res(scope, receive, send)
                return

            tenant_context.set(tenant_id)

            # Ensure Accept header includes application/json
            if b"accept" not in headers or not headers[b"accept"]:
                new_headers = list(scope.get("headers", []))
                new_headers.append((b"accept", b"application/json, text/event-stream"))
                scope["headers"] = new_headers

        session_manager = get_streamable_session_manager()
        await session_manager.handle_request(scope, receive, send)


def register_mcp_transport_routes(
    app_router, get_tenant_id, verify_infrastructure_access, limiter, config
):
    """Register MCP transport routes (SSE and Stateless Streamable HTTP)."""

    streamable_handler = _StreamableHttpApp(app_router, get_tenant_id)
    app_router.add_route(
        "/mcp", streamable_handler, methods=["GET", "POST", "DELETE", "OPTIONS"]
    )
    app_router.add_route(
        "/mcp/", streamable_handler, methods=["GET", "POST", "DELETE", "OPTIONS"]
    )

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
