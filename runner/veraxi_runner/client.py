"""Outbound WebSocket client for ``veraxi-runner``.

Connects to ``{url}/api/v1/sandboxes/runner/ws`` with the per-tenant
runner token, then serves JSON-RPC requests (``exec`` / ``read_file`` /
``write_file`` / ``diff``) through :class:`LocalExecutor`, streaming
exec events back as individual messages sharing the request id.
"""

import asyncio
import json
import logging

from veraxi_runner.local_exec import LocalExecutor

logger = logging.getLogger(__name__)


def runner_ws_url(base_url: str, tenant_id: str, token: str) -> str:
    """Build the runner websocket URL (token travels as a query param
    because browsers/websockets cannot set headers uniformly; the
    backend validates it against the tenant's encrypted runner token).
    """
    from urllib.parse import quote

    base = base_url.rstrip("/")
    return (
        f"{base}/api/v1/sandboxes/runner/ws"
        f"?tenant_id={quote(tenant_id)}&token={quote(token)}"
    )


async def _serve_connection(websocket, executor: LocalExecutor) -> None:
    async for raw in websocket:
        try:
            message = json.loads(raw)
        except ValueError:
            logger.warning("Ignoring non-JSON message from backend")
            continue
        request_id = message.get("id")
        method = message.get("method") or ""
        params = message.get("params") or {}

        async def emit(event: dict, _rid=request_id) -> None:
            await websocket.send(json.dumps({"jsonrpc": "2.0", "id": _rid, "result": event}))

        try:
            result = await executor.handle(method, params, emit=emit if method == "exec" else None)
            if method == "exec":
                # Streaming events already carried the exit event.
                continue
            await websocket.send(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}))
        except Exception as e:  # Report per-request errors, keep serving.
            logger.error("Runner request %s failed: %s", method, e)
            await websocket.send(
                json.dumps({"jsonrpc": "2.0", "id": request_id, "error": str(e)})
            )


async def connect_and_serve(
    url: str, token: str, repo: str, runtime: str = "docker",
    tenant_id: str = "", offline: bool = False,
) -> None:
    """Connect outbound and serve requests until disconnected."""
    try:
        import websockets  # Lazy: declared in runner/pyproject.toml.
    except ImportError as e:
        raise RuntimeError(
            "The `websockets` package is required: pip install veraxi-runner"
        ) from e
    executor = LocalExecutor(repo, runtime=runtime, offline=offline)
    ws_url = runner_ws_url(url, tenant_id, token)
    async with websockets.connect(ws_url) as websocket:
        logger.info("veraxi-runner connected (repo=%s runtime=%s)", repo, runtime)
        await _serve_connection(websocket, executor)


def run_connect(url: str, token: str, repo: str, runtime: str, tenant_id: str = "", offline: bool = False) -> None:
    asyncio.run(connect_and_serve(url, token, repo, runtime, tenant_id, offline))
