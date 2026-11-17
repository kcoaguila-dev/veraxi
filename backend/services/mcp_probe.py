"""Minimal MCP handshake probe used when adding/testing integrations.

Connects to a remote MCP server, initializes a session, and returns
its tool names. The full hardened runtime lives in
``services/mcp_client_manager.py``; this probe is intentionally small
and is only used for connectivity checks, never for chat tool calls.
"""

import asyncio
import logging
from contextlib import AsyncExitStack

import sentry_sdk
from mcp import ClientSession
from mcp.client.sse import sse_client
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

logger = logging.getLogger(__name__)

DISCOVERY_TIMEOUT_SECONDS = 10.0


async def _list_tools_with_transport(url: str, headers: dict, transport: str) -> list[str]:
    stack = AsyncExitStack()
    try:
        if transport == "sse":
            streams = await stack.enter_async_context(
                sse_client(url, headers=headers or None)
            )
        else:
            http_client = create_mcp_http_client(headers=headers or None)
            await stack.enter_async_context(http_client)
            streams = await stack.enter_async_context(
                streamable_http_client(url, http_client=http_client)
            )
        read_stream, write_stream = streams[0], streams[1]
        session = await stack.enter_async_context(
            ClientSession(read_stream, write_stream)
        )
        await session.initialize()
        result = await session.list_tools()
        return [tool.name for tool in result.tools]
    finally:
        await stack.aclose()


async def probe_mcp_tools(url: str, headers: dict, transport: str = "auto") -> list[str]:
    """Return the tool names advertised by an MCP server.

    ``transport="auto"`` tries Streamable HTTP first and falls back to
    SSE on any failure. Raises the underlying exception on failure.
    """
    transports = ["streamable_http", "sse"] if transport == "auto" else [transport]
    last_error: Exception | None = None
    for candidate in transports:
        try:
            return await asyncio.wait_for(
                _list_tools_with_transport(url, headers, candidate),
                timeout=DISCOVERY_TIMEOUT_SECONDS,
            )
        except Exception as e:  # fallback/reporting boundary
            last_error = e
            logger.warning("MCP probe via %s failed for %s: %s", candidate, url, e)
    if last_error is not None:
        sentry_sdk.capture_exception(last_error)
        raise last_error
    raise RuntimeError("MCP probe failed without an error")
