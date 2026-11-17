"""OpenAPI / REST action importer.

Turns a tenant-supplied OpenAPI 3.0/3.1 spec (JSON or YAML, pasted or
fetched from an SSRF-validated URL) into a small set of LLM tools
without requiring an MCP server:

- :func:`parse_spec` / :func:`list_operations` power the preview step.
- Selected operations (max :data:`MAX_OPERATIONS` per integration, to
  protect small-model context budgets) are stored as compiled
  operation definitions on the integration row.
- :func:`get_openapi_tools` compiles them to ``api__{slug}__{op_id}``
  function schemas; :func:`execute_openapi_tool` runs them via httpx
  with the integration's encrypted auth, re-validating the target URL
  through the SSRF guard immediately before the request, and truncates
  responses at 16 KB before they reach the LLM.
- Non-GET operations are mutating: the dispatch layer gates them
  behind the same confirmation mechanism as GitHub writes
  (:func:`openapi_requires_confirmation`).
"""

import asyncio
import json
import logging
import re

import httpx
import sentry_sdk
import yaml

from backend.security.ssrf import validate_external_url
from backend.services import integration_store as store

logger = logging.getLogger(__name__)

MAX_OPERATIONS = 10
MAX_RESPONSE_BYTES = 16_384
_HTTP_METHODS = ("get", "post", "put", "patch", "delete", "head", "options")
_OP_INVALID = re.compile(r"[^a-zA-Z0-9_]")


def parse_spec(spec_text: str) -> dict:
    """Parse an OpenAPI spec from JSON or YAML text."""
    if not spec_text or not spec_text.strip():
        raise ValueError("OpenAPI spec is empty")
    data = None
    try:
        data = json.loads(spec_text)
    except ValueError:
        try:
            data = yaml.safe_load(spec_text)
        except yaml.YAMLError as e:
            raise ValueError("Spec is neither valid JSON nor valid YAML") from e
    if not isinstance(data, dict):
        raise ValueError("OpenAPI spec must be a JSON/YAML object")  # noqa: TRY004 - uniform parse-error type for the routes layer
    version = str(data.get("openapi") or "")
    if not version.startswith("3."):
        raise ValueError(f"Only OpenAPI 3.x specs are supported (got {version!r})")
    if not isinstance(data.get("paths"), dict):
        raise ValueError("OpenAPI spec has no paths object")  # noqa: TRY004 - uniform parse-error type for the routes layer
    return data


async def fetch_spec_text(spec_url: str) -> str:
    """Fetch a spec from an SSRF-validated URL."""
    from urllib.parse import urlparse, urlunparse

    validated_url = validate_external_url(spec_url)
    parsed = urlparse(validated_url.strip())
    scheme = "https" if parsed.scheme == "https" else "http"
    safe_url = urlunparse(
        (scheme, parsed.netloc, parsed.path, parsed.params, parsed.query, "")
    )
    async with httpx.AsyncClient(timeout=30.0, follow_redirects=False) as client:
        response = await client.get(safe_url)
        response.raise_for_status()
        return response.text


def sanitize_operation_id(raw: str, method: str, path: str) -> str:
    """LLM-safe operation id (falls back to method+path when missing)."""
    candidate = _OP_INVALID.sub("_", (raw or "").strip())
    if not candidate:
        candidate = _OP_INVALID.sub("_", f"{method}_{path}").strip("_")
    return candidate[:48]


def list_operations(spec: dict) -> list[dict]:
    """Selectable operations in a parsed spec (document order)."""
    default_server = ""
    servers = spec.get("servers") or []
    if servers and isinstance(servers[0], dict):
        default_server = servers[0].get("url", "")
    operations: list[dict] = []
    for path, path_item in (spec.get("paths") or {}).items():
        if not isinstance(path_item, dict):
            continue
        for method in _HTTP_METHODS:
            operation = path_item.get(method)
            if not isinstance(operation, dict):
                continue
            op_id = sanitize_operation_id(
                operation.get("operationId", ""), method, path
            )
            op_servers = operation.get("servers") or []
            server_url = (
                op_servers[0].get("url", "")
                if op_servers and isinstance(op_servers[0], dict)
                else default_server
            )
            operations.append(
                {
                    "operation_id": op_id,
                    "method": method.upper(),
                    "path": path,
                    "summary": operation.get("summary", ""),
                    "server_url": server_url,
                }
            )
    return operations


def _operation_parameters(spec: dict, path: str, method: str) -> tuple[list[dict], dict | None]:
    """Return (parameters, request-body JSON schema) for one operation."""
    operation = (spec.get("paths") or {}).get(path, {}).get(method.lower(), {})
    parameters = [
        p
        for p in operation.get("parameters", [])
        if isinstance(p, dict) and p.get("name")
    ]
    body_schema = None
    content = (operation.get("requestBody") or {}).get("content") or {}
    for media in content.values():
        if isinstance(media, dict) and isinstance(media.get("schema"), dict):
            body_schema = media["schema"]
            break
    return parameters, body_schema


def compile_operations(spec: dict, selected_ids: list[str], server_url_override: str = "") -> list[dict]:
    """Compile selected operations into storable definitions.

    Raises ValueError when a selected id is unknown, when more than
    MAX_OPERATIONS are selected, or when an operation has no server
    URL (relative servers cannot be executed safely).
    """
    if len(selected_ids) > MAX_OPERATIONS:
        raise ValueError(
            f"Select at most {MAX_OPERATIONS} operations per integration"
        )
    available = {op["operation_id"]: op for op in list_operations(spec)}
    compiled: list[dict] = []
    for op_id in selected_ids:
        op = available.get(op_id)
        if op is None:
            raise ValueError(f"Unknown operationId: {op_id}")
        server_url = server_url_override or op["server_url"]
        if not server_url or server_url.startswith("/"):
            raise ValueError(
                f"Operation {op_id} has no absolute server URL; "
                "provide a server URL override"
            )
        validate_external_url(server_url)
        parameters, body_schema = _operation_parameters(spec, op["path"], op["method"])
        compiled.append(
            {
                "operation_id": op_id,
                "method": op["method"],
                "path": op["path"],
                "server_url": server_url.rstrip("/"),
                "parameters": parameters,
                "request_body_schema": body_schema,
            }
        )
    return compiled


def tool_name_for(slug: str, operation_id: str) -> str:
    return f"api__{slug}__{operation_id}"


def operation_to_schema(slug: str, op: dict) -> dict:
    """Compile one stored operation into an OpenAI function schema."""
    properties: dict = {}
    required: list[str] = []
    for param in op.get("parameters") or []:
        if param.get("in") not in ("path", "query", "header"):
            continue
        schema = param.get("schema") or {"type": "string"}
        properties[param["name"]] = {
            "type": schema.get("type", "string"),
            "description": param.get("description", f"{param['in']} parameter"),
        }
        if param.get("required"):
            required.append(param["name"])
    body_schema = op.get("request_body_schema") or {}
    for prop_name, prop_schema in (body_schema.get("properties") or {}).items():
        if prop_name in properties:
            continue
        properties[prop_name] = {
            "type": (prop_schema or {}).get("type", "string"),
            "description": f"Request body field {prop_name}",
        }
    for req in body_schema.get("required") or []:
        if req in properties and req not in required:
            required.append(req)
    description = (
        f"{op['method']} {op['path']} on the {slug} API integration."
    )
    if op["method"] != "GET":
        description += " This operation changes external state and requires user confirmation."
    return {
        "type": "function",
        "function": {
            "name": tool_name_for(slug, op["operation_id"]),
            "description": description,
            "parameters": {
                "type": "object",
                "properties": properties,
                "required": required,
            },
        },
    }


def _default_supabase():
    try:
        from backend.api_gateway import _get_supabase

        return _get_supabase()
    except Exception as e:
        sentry_sdk.capture_exception(e)
        return None


def _openapi_rows(sb, tenant_id: str, tool_settings: dict | None) -> list[dict]:
    rows = [
        r
        for r in store.list_enabled_integrations(sb, tenant_id)
        if r.get("kind") == "openapi"
    ]
    selected = (tool_settings or {}).get("enabled_integration_ids")
    if isinstance(selected, list):
        wanted = {str(v) for v in selected}
        rows = [r for r in rows if str(r.get("id")) in wanted]
    return rows


async def get_openapi_tools(tenant_id: str | None, tool_settings: dict | None = None) -> list[dict]:
    """Schemas for the tenant's enabled OpenAPI integrations."""
    if not tenant_id:
        return []
    sb = _default_supabase()
    if sb is None:
        return []
    try:
        rows = await asyncio.to_thread(_openapi_rows, sb, tenant_id, tool_settings)
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("Failed to load OpenAPI integrations for tenant %s: %s", tenant_id, e)
        return []
    schemas: list[dict] = []
    for row in rows:
        for op in (row.get("config") or {}).get("operations") or []:
            schemas.append(operation_to_schema(row.get("slug") or "api", op))
    return schemas


def _find_operation(sb, tenant_id: str, slug: str, operation_id: str) -> tuple[dict, dict] | None:
    for row in store.list_enabled_integrations(sb, tenant_id):
        if row.get("kind") != "openapi" or row.get("slug") != slug:
            continue
        for op in (row.get("config") or {}).get("operations") or []:
            if op.get("operation_id") == operation_id:
                return row, op
    return None


def _parse_api_tool_name(tool_name: str) -> tuple[str, str] | None:
    parts = tool_name.split("__", 2)
    if len(parts) != 3 or parts[0] != "api":
        return None
    return parts[1], parts[2]


async def openapi_requires_confirmation(tenant_id: str, tool_name: str) -> bool:
    """True when an ``api__`` tool maps to a non-GET operation."""
    parsed = _parse_api_tool_name(tool_name)
    if not parsed or not tenant_id:
        return False
    sb = _default_supabase()
    if sb is None:
        return False
    slug, operation_id = parsed
    try:
        found = await asyncio.to_thread(
            _find_operation, sb, tenant_id, slug, operation_id
        )
    except Exception as e:
        sentry_sdk.capture_exception(e)
        return True  # Unverifiable mutating state: fail closed to the gate.
    if not found:
        return False
    _row, op = found
    return op.get("method", "GET") != "GET"


def _auth_for(row: dict) -> tuple[dict, dict]:
    """Build (headers, query params) from the integration's secrets/config."""
    secrets_payload = store.decrypt_row_secrets(row)
    auth = (row.get("config") or {}).get("auth") or {}
    auth_type = auth.get("type", "bearer")
    headers: dict = {}
    params: dict = {}
    if auth_type == "bearer":
        token = secrets_payload.get("access_token") or secrets_payload.get("api_key", "")
        if token:
            headers["Authorization"] = f"Bearer {token}"
    elif auth_type == "api_key_header" and secrets_payload.get("api_key"):
        headers[auth.get("name", "X-API-Key")] = secrets_payload["api_key"]
    elif auth_type == "api_key_query" and secrets_payload.get("api_key"):
        params[auth.get("name", "api_key")] = secrets_payload["api_key"]
    return headers, params


async def _http_request(method: str, url: str, **kwargs) -> httpx.Response:
    """Seam for tests: the single place OpenAPI calls leave the process."""
    async with httpx.AsyncClient(timeout=30.0) as client:
        return await client.request(method, url, **kwargs)


async def execute_openapi_tool(tool_name: str, tool_input: dict, tenant_id: str) -> str:
    """Execute one imported OpenAPI operation and return truncated text."""
    parsed = _parse_api_tool_name(tool_name)
    if not parsed:
        return f"Unknown OpenAPI tool: {tool_name}"
    sb = _default_supabase()
    if sb is None:
        return "OpenAPI integration storage is unavailable"
    slug, operation_id = parsed
    try:
        found = await asyncio.to_thread(
            _find_operation, sb, tenant_id, slug, operation_id
        )
    except Exception as e:
        sentry_sdk.capture_exception(e)
        return f"OpenAPI tool {tool_name} failed: {e}"
    if not found:
        return f"OpenAPI operation {operation_id} is not enabled for this tenant"
    row, op = found
    return await _execute_operation(row, op, tool_input)


async def _execute_operation(row: dict, op: dict, args: dict) -> str:
    path = op["path"]
    query: dict = {}
    body: dict = {}
    param_locations = {
        p["name"]: p.get("in") for p in op.get("parameters") or []
    }
    body_props = set(((op.get("request_body_schema") or {}).get("properties") or {}).keys())
    for key, value in (args or {}).items():
        location = param_locations.get(key)
        if location == "path":
            path = path.replace("{" + key + "}", str(value))
        elif location == "query":
            query[key] = value
        elif key in body_props:
            body[key] = value
    if "{" in path:
        return f"Missing required path parameters for {op['method']} {op['path']}"
    url = f"{op['server_url']}{path}"
    # Re-validate immediately before connecting (DNS rebinding guard).
    validate_external_url(url)
    headers, auth_params = _auth_for(row)
    query.update(auth_params)
    try:
        response = await _http_request(
            op["method"],
            url,
            params=query or None,
            json=body or None,
            headers=headers or None,
        )
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("OpenAPI call failed for %s %s: %s", op["method"], url, e)
        return f"OpenAPI call failed: {e}"
    text = response.text or ""
    if len(text.encode()) > MAX_RESPONSE_BYTES:
        text = text.encode()[:MAX_RESPONSE_BYTES].decode("utf-8", errors="replace")
        text += "\n…[truncated at 16 KB]"
    status = response.status_code
    if status >= 400:
        return f"OpenAPI call returned HTTP {status}: {text}"
    return text or f"OpenAPI call succeeded (HTTP {status})"
