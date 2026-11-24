"""Outbound WebSocket client for ``veraxi-runner``.

Connects to ``{url}/api/v1/sandboxes/runner/ws`` with the per-tenant
runner token, then serves JSON-RPC requests (``exec`` / ``read_file`` /
``write_file`` / ``diff``) through :class:`LocalExecutor`, streaming
exec events back as individual messages sharing the request id.
"""

import asyncio
import json
import logging

from veraxi_runner.acp_bridge import RunnerAcpBridge
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


async def _serve_connection(
    websocket,
    executor: LocalExecutor,
    acp_bridge: RunnerAcpBridge | None = None,
) -> None:
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

        async def emit_acp(event: dict, _rid=request_id) -> None:
            await websocket.send(
                json.dumps({"jsonrpc": "2.0", "id": _rid, "acp_event": True, "result": event})
            )

        try:
            if method.startswith("acp."):
                if acp_bridge is None:
                    raise RuntimeError("ACP bridge is not enabled on this runner")
                if method == "acp.prompt":
                    asyncio.create_task(
                        _run_acp_prompt_task(websocket, acp_bridge, request_id, params, emit_acp)
                    )
                    continue
                result = await acp_bridge.handle(method, params, emit=emit_acp)
                await websocket.send(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}))
                continue

            result = await executor.handle(method, params, emit=emit if method == "exec" else None)
            if method == "exec":
                # Streaming events already carried the exit event.
                continue
            await websocket.send(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}))
        except Exception as e:  # Report per-request errors, keep serving.
            logger.error("Runner request %s failed: %s", method, e)
            payload = {"jsonrpc": "2.0", "id": request_id, "error": str(e)}
            if method.startswith("acp."):
                payload["acp_event"] = True
            await websocket.send(json.dumps(payload))


async def _run_acp_prompt_task(websocket, acp_bridge: RunnerAcpBridge, request_id, params: dict, emit_acp) -> None:
    try:
        await acp_bridge.handle("acp.prompt", params, emit=emit_acp)
    except Exception as exc:
        logger.error("Runner acp.prompt failed: %s", exc)
        await websocket.send(
            json.dumps({"jsonrpc": "2.0", "id": request_id, "acp_event": True, "error": str(exc)})
        )


async def connect_and_serve(
    url: str, token: str, repo: str, runtime: str = "docker",
    tenant_id: str = "", offline: bool = False, enable_acp: bool = False,
) -> None:
    """Connect outbound and serve requests until disconnected."""
    try:
        import websockets  # Lazy: declared in runner/pyproject.toml.
    except ImportError as e:
        raise RuntimeError(
            "The `websockets` package is required: pip install veraxi-runner"
        ) from e
    executor = LocalExecutor(repo, runtime=runtime, offline=offline)
    acp_bridge = RunnerAcpBridge(repo, enabled=enable_acp)
    ws_url = runner_ws_url(url, tenant_id, token)
    async with websockets.connect(ws_url) as websocket:
        logger.info("veraxi-runner connected (repo=%s runtime=%s acp=%s)", repo, runtime, enable_acp)
        await _serve_connection(websocket, executor, acp_bridge=acp_bridge)


def run_connect(
    url: str, token: str, repo: str, runtime: str,
    tenant_id: str = "", offline: bool = False, enable_acp: bool = False,
) -> None:
    asyncio.run(
        connect_and_serve(url, token, repo, runtime, tenant_id, offline, enable_acp=enable_acp)
    )
