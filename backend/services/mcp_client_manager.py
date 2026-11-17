"""Hardened outbound MCP runtime for tenant integrations.

Owns everything about talking to external MCP servers on a tenant's
behalf:

- Loads enabled ``mcp`` integrations for the tenant from
  ``tenant_integrations`` (decrypting auth headers server-side only),
  falling back to the legacy ``tool_settings["mcp_servers"]`` list when
  the tenant has no stored integrations — the legacy path keeps the
  historical ``skills_enabled`` gate so existing clients behave the
  same until they migrate.
- Transports: Streamable HTTP first, SSE fallback on HTTP 404/405 when
  the integration transport is ``auto``.
- Tool names are namespaced ``mcp__{slug}__{tool}`` and sanitized to
  ``^[a-zA-Z0-9_-]{1,64}$`` with a hash-suffix truncation.
- Tool schemas are cached per ``(tenant_id, integration_id)`` with a
  5-minute TTL; routes invalidate entries on PATCH/DELETE/test.
- Every connection re-validates the URL through the SSRF guard (DNS
  rebinding protection), with a 10s discovery / 30s call timeout.
- Per-chat ``enabled_integration_ids`` in ``tool_settings`` filters
  which integrations are attached, and injected external tools are
  capped at :data:`MAX_EXTERNAL_TOOLS` to protect small-model context
  windows.
"""

import asyncio
import hashlib
import logging
import re
import time
from contextlib import AsyncExitStack
from dataclasses import dataclass, field

import sentry_sdk
from mcp import ClientSession
from mcp.client.sse import sse_client
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

from backend.security.ssrf import validate_external_url
from backend.services import integration_store as store

logger = logging.getLogger(__name__)

MAX_EXTERNAL_TOOLS = 15
CACHE_TTL_SECONDS = 300.0
DISCOVERY_TIMEOUT_SECONDS = 10.0
CALL_TIMEOUT_SECONDS = 30.0

_NAME_INVALID = re.compile(r"[^a-zA-Z0-9_-]")
_NAME_VALID = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")


@dataclass
class McpServerSpec:
    """One outbound MCP server a tenant can attach to a chat."""

    slug: str
    url: str
    transport: str = "auto"
    headers: dict = field(default_factory=dict)
    integration_id: str = ""
    display_name: str = ""


@dataclass
class _CacheEntry:
    expires_at: float
    tools: list[dict]
    name_map: dict  # sanitized full name -> original tool name


_CACHE: dict[tuple[str, str], _CacheEntry] = {}


def invalidate_cache(integration_id: str | None = None, tenant_id: str | None = None) -> None:
    """Drop cached tool schemas (all, or one tenant/integration)."""
    if integration_id is None and tenant_id is None:
        _CACHE.clear()
        return
    for key in list(_CACHE):
        if tenant_id is not None and key[0] != tenant_id:
            continue
        if integration_id is not None and key[1] != integration_id:
            continue
        _CACHE.pop(key, None)


def sanitize_tool_name(slug: str, tool_name: str) -> str:
    """Namespace and sanitize a tool name to the 64-char LLM-safe form."""
    clean_slug = _NAME_INVALID.sub("_", slug or "server")
    clean_tool = _NAME_INVALID.sub("_", tool_name or "tool")
    full = f"mcp__{clean_slug}__{clean_tool}"
    if len(full) <= 64:
        return full
    digest = hashlib.sha256(full.encode()).hexdigest()[:8]
    # Reserve room for "__" separators already counted in the budget:
    # truncate the tool portion and append _<hash> to stay unique.
    budget = 64 - len(f"mcp__{clean_slug}__") - len(f"_{digest}")
    if budget < 1:
        clean_slug = clean_slug[: 64 - len("mcp____") - len(f"_{digest}") - 1]
        budget = 64 - len(f"mcp__{clean_slug}__") - len(f"_{digest}")
    return f"mcp__{clean_slug}__{clean_tool[:budget]}_{digest}"


def _default_supabase():
    """Lazy gateway Supabase accessor (module-level import would cycle)."""
    try:
        from backend.api_gateway import _get_supabase

        return _get_supabase()
    except Exception as e:
        sentry_sdk.capture_exception(e)
        return None


def _specs_from_integrations(rows: list[dict], tool_settings: dict | None) -> list[McpServerSpec]:
    selected = None
    if tool_settings:
        raw = tool_settings.get("enabled_integration_ids")
        if isinstance(raw, list):
            selected = {str(v) for v in raw}
    specs: list[McpServerSpec] = []
    for row in rows:
        if row.get("kind") != "mcp":
            continue
        if selected is not None and str(row.get("id")) not in selected:
            continue
        cfg = row.get("config") or {}
        url = cfg.get("url")
        if not url:
            continue
        secrets = store.decrypt_row_secrets(row)
        headers = dict(secrets.get("headers") or {})
        token = secrets.get("access_token")
        if token and "Authorization" not in headers:
            headers["Authorization"] = f"Bearer {token}"
        specs.append(
            McpServerSpec(
                slug=row.get("slug") or "server",
                url=url,
                transport=cfg.get("transport", "auto"),
                headers=headers,
                integration_id=str(row.get("id") or ""),
                display_name=row.get("display_name") or "",
            )
        )
    return specs


def _specs_from_legacy(tool_settings: dict | None) -> list[McpServerSpec]:
    """Legacy SharedPreferences servers (keeps the skills_enabled gate)."""
    if not tool_settings or not tool_settings.get("skills_enabled"):
        return []
    specs: list[McpServerSpec] = []
    for server in tool_settings.get("mcp_servers", []) or []:
        if not server.get("enabled", True) or not server.get("url"):
            continue
        name = server.get("name") or "server"
        specs.append(
            McpServerSpec(
                slug=store.slugify(name) or "server",
                url=server["url"],
                transport=server.get("transport", "auto"),
                headers=dict(server.get("headers") or {}),
                integration_id=f"legacy:{name}",
                display_name=name,
            )
        )
    return specs


def load_server_specs(
    tenant_id: str | None,
    tool_settings: dict | None = None,
    supabase=None,
) -> list[McpServerSpec]:
    """Resolve the MCP server specs for a tenant/chat.

    Stored integrations win; the legacy list is used only when the
    tenant has no stored integrations (or storage is unavailable).
    """
    rows: list[dict] = []
    if tenant_id:
        sb = supabase if supabase is not None else _default_supabase()
        if sb is not None:
            try:
                rows = store.list_enabled_integrations(sb, tenant_id)
            except Exception as e:
                sentry_sdk.capture_exception(e)
                logger.error("Failed to load integrations for tenant %s: %s", tenant_id, e)
    specs = _specs_from_integrations(rows, tool_settings)
    if specs:
        return specs
    # Per-chat selection that matches nothing stored must not silently
    # widen to legacy servers.
    if tool_settings and isinstance(tool_settings.get("enabled_integration_ids"), list):
        return []
    return _specs_from_legacy(tool_settings)


async def _open_session(spec: McpServerSpec, transport: str, stack: AsyncExitStack):
    if transport == "sse":
        streams = await stack.enter_async_context(
            sse_client(spec.url, headers=spec.headers or None)
        )
    else:
        http_client = create_mcp_http_client(headers=spec.headers or None)
        await stack.enter_async_context(http_client)
        streams = await stack.enter_async_context(
            streamable_http_client(spec.url, http_client=http_client)
        )
    session = await stack.enter_async_context(
        ClientSession(streams[0], streams[1])
    )
    await session.initialize()
    return session


def _is_fallback_worthy(exc: Exception) -> bool:
    status = getattr(exc, "status_code", None) or getattr(
        getattr(exc, "response", None), "status_code", None
    )
    if status in (404, 405):
        return True
    text = str(exc)
    return "404" in text or "405" in text


async def _with_session(spec: McpServerSpec, action):
    """Run ``action(session)`` with transport selection + SSRF + fallback."""
    validate_external_url(spec.url)
    transports = (
        ["streamable_http", "sse"] if spec.transport == "auto" else [spec.transport]
    )
    last_error: Exception | None = None
    for transport in transports:
        stack = AsyncExitStack()
        try:
            session = await _open_session(spec, transport, stack)
            return await action(session)
        except Exception as e:
            last_error = e
            if transport == transports[-1] or not _is_fallback_worthy(e):
                sentry_sdk.capture_exception(e)
                raise
            logger.warning(
                "MCP transport %s failed for %s (%s); falling back",
                transport,
                spec.url,
                e,
            )
        finally:
            await stack.aclose()
    if last_error is not None:
        raise last_error
    raise RuntimeError("MCP session failed without an error")


async def discover_tools(spec: McpServerSpec, tenant_id: str) -> list[dict]:
    """Return OpenAI-style tool schemas for a server (cached per tenant)."""
    cache_key = (tenant_id or "", spec.integration_id or spec.slug)
    entry = _CACHE.get(cache_key)
    if entry and entry.expires_at > time.monotonic():
        return entry.tools

    async def _list(session):
        result = await session.list_tools()
        tools: list[dict] = []
        name_map: dict[str, str] = {}
        for tool in result.tools:
            full_name = sanitize_tool_name(spec.slug, tool.name)
            name_map[full_name] = tool.name
            tools.append(
                {
                    "type": "function",
                    "function": {
                        "name": full_name,
                        "description": tool.description or "MCP Dynamic Tool",
                        "parameters": tool.input_schema
                        or {"type": "object", "properties": {}},
                    },
                }
            )
        return tools, name_map

    tools, name_map = await asyncio.wait_for(
        _with_session(spec, _list), timeout=DISCOVERY_TIMEOUT_SECONDS
    )
    _CACHE[cache_key] = _CacheEntry(
        expires_at=time.monotonic() + CACHE_TTL_SECONDS,
        tools=tools,
        name_map=name_map,
    )
    return tools


async def get_external_tools(
    tenant_id: str | None,
    tool_settings: dict | None = None,
    supabase=None,
) -> list[dict]:
    """All external MCP tool schemas for a chat, capped at the limit."""
    specs = load_server_specs(tenant_id, tool_settings, supabase=supabase)
    collected: list[dict] = []
    for spec in specs:
        try:
            collected.extend(await discover_tools(spec, tenant_id or ""))
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error("Failed to fetch tools from MCP server %s: %s", spec.url, e)
    if len(collected) > MAX_EXTERNAL_TOOLS:
        logger.warning(
            "Capping external MCP tools at %d (had %d) for tenant %s",
            MAX_EXTERNAL_TOOLS,
            len(collected),
            tenant_id,
        )
        collected = collected[:MAX_EXTERNAL_TOOLS]
    return collected


async def call_tool(
    spec: McpServerSpec,
    tenant_id: str,
    full_tool_name: str,
    tool_input: dict,
):
    """Execute one tool call on a server and return the SDK result."""
    entry = _CACHE.get((tenant_id or "", spec.integration_id or spec.slug))
    original = entry.name_map.get(full_tool_name) if entry else None
    if original is None:
        parts = full_tool_name.split("__", 2)
        original = parts[2] if len(parts) == 3 else full_tool_name

    async def _call(session):
        return await session.call_tool(original, tool_input)

    return await asyncio.wait_for(
        _with_session(spec, _call), timeout=CALL_TIMEOUT_SECONDS
    )


def find_spec(
    specs: list[McpServerSpec], slug: str
) -> McpServerSpec | None:
    for spec in specs:
        if spec.slug == slug:
            return spec
    return None
