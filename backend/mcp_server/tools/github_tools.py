"""Curated GitHub connector tools.

A deliberately tight toolset (not the whole GitHub REST API) exposed
to the LLM when the tenant has an active GitHub OAuth integration.
Read tools execute immediately; mutating tools are marked in
:data:`GATED_TOOLS` and the dispatch layer refuses to run them without
an explicit user confirmation (see the tool-confirmation gate in
``tool_dispatch.execute_tools_internal``).

All calls go to ``https://api.github.com`` with the tenant's decrypted
OAuth token, resolved through
:func:`backend.services.oauth_service.get_valid_access_token` so
expired tokens refresh transparently.
"""

import base64
import logging

import httpx
import sentry_sdk

logger = logging.getLogger(__name__)

GITHUB_API_BASE = "https://api.github.com"
_MAX_RESPONSE_CHARS = 8000

# Mutating tools: dispatch must not execute these without confirmation.
GATED_TOOLS = {"github_create_issue", "github_comment_pr"}

TOOL_DEFS: list[dict] = [
    {
        "name": "github_search_code",
        "description": "Search code in GitHub repositories the user has connected.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query."},
                "repo": {
                    "type": "string",
                    "description": "Optional owner/repo to restrict the search to.",
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "github_get_file",
        "description": "Fetch a file's text content from a GitHub repository.",
        "parameters": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/repo."},
                "path": {"type": "string", "description": "Path within the repo."},
                "ref": {"type": "string", "description": "Optional branch/tag/SHA."},
            },
            "required": ["repo", "path"],
        },
    },
    {
        "name": "github_list_issues_or_prs",
        "description": "List issues or pull requests for a GitHub repository.",
        "parameters": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/repo."},
                "state": {
                    "type": "string",
                    "enum": ["open", "closed", "all"],
                    "description": "Filter by state (default open).",
                },
                "type": {
                    "type": "string",
                    "enum": ["issue", "pr"],
                    "description": "List issues or pull requests.",
                },
            },
            "required": ["repo", "type"],
        },
    },
    {
        "name": "github_get_pr_diff",
        "description": "Fetch the unified diff of a pull request.",
        "parameters": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/repo."},
                "pr_number": {"type": "integer", "description": "Pull request number."},
            },
            "required": ["repo", "pr_number"],
        },
    },
    {
        "name": "github_create_issue",
        "description": "Create a GitHub issue. Requires user confirmation before it runs.",
        "parameters": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/repo."},
                "title": {"type": "string", "description": "Issue title."},
                "body": {"type": "string", "description": "Issue body (Markdown)."},
            },
            "required": ["repo", "title"],
        },
    },
    {
        "name": "github_comment_pr",
        "description": "Comment on a pull request. Requires user confirmation before it runs.",
        "parameters": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/repo."},
                "pr_number": {"type": "integer", "description": "Pull request number."},
                "body": {"type": "string", "description": "Comment body (Markdown)."},
            },
            "required": ["repo", "pr_number", "body"],
        },
    },
]


def requires_confirmation(tool_name: str) -> bool:
    return tool_name in GATED_TOOLS


def tool_schemas() -> list[dict]:
    """OpenAI-style function schemas for the curated GitHub tools."""
    return [
        {
            "type": "function",
            "function": {
                "name": d["name"],
                "description": d["description"],
                "parameters": d["parameters"],
            },
        }
        for d in TOOL_DEFS
    ]


def _default_supabase():
    try:
        from backend.api_gateway import _get_supabase

        return _get_supabase()
    except Exception as e:
        sentry_sdk.capture_exception(e)
        return None


async def _resolve_token(tenant_id: str, supabase=None) -> str:
    """Seam: resolve the tenant's valid GitHub access token."""
    from backend.config import get_config
    from backend.services.oauth_service import get_valid_access_token

    sb = supabase if supabase is not None else _default_supabase()
    if sb is None:
        raise ValueError("GitHub integration storage is unavailable")
    return await get_valid_access_token(get_config(), sb, tenant_id, "github")


async def get_github_tools(tenant_id: str | None, tool_settings: dict | None = None) -> list[dict]:
    """Schemas when the tenant has an active GitHub integration, else []."""
    if not tenant_id:
        return []
    sb = _default_supabase()
    if sb is None:
        return []
    try:
        import asyncio

        from backend.services import integration_store as store

        row = await asyncio.to_thread(
            store.get_integration_by_provider, sb, tenant_id, "github"
        )
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("Failed to check GitHub integration for tenant %s: %s", tenant_id, e)
        return []
    if not row or not row.get("is_enabled", True):
        return []
    selected = (tool_settings or {}).get("enabled_integration_ids")
    if isinstance(selected, list) and str(row.get("id")) not in {
        str(v) for v in selected
    }:
        return []
    return tool_schemas()


def _truncate(text: str) -> str:
    if len(text) <= _MAX_RESPONSE_CHARS:
        return text
    return text[:_MAX_RESPONSE_CHARS] + "\n…[truncated]"


async def _github_request(token: str, method: str, path: str, **kwargs) -> httpx.Response:
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": kwargs.pop("accept", "application/vnd.github+json"),
        "X-GitHub-Api-Version": "2022-11-28",
    }
    async with httpx.AsyncClient(base_url=GITHUB_API_BASE, timeout=30.0) as client:
        response = await client.request(method, path, headers=headers, **kwargs)
        response.raise_for_status()
        return response


async def execute_github_tool(
    tool_name: str, tool_input: dict, tenant_id: str, supabase=None
) -> str:
    """Execute one curated GitHub tool and return a text result."""
    token = await _resolve_token(tenant_id, supabase=supabase)
    try:
        return await _execute_with_token(tool_name, tool_input, token)
    except httpx.HTTPStatusError as e:
        sentry_sdk.capture_exception(e)
        return f"GitHub API error ({e.response.status_code}) for {tool_name}."
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error("GitHub tool %s failed: %s", tool_name, e)
        return f"GitHub tool {tool_name} failed: {e}"


async def _execute_with_token(tool_name: str, args: dict, token: str) -> str:
    if tool_name == "github_search_code":
        query = args["query"]
        if args.get("repo"):
            query = f"{query} repo:{args['repo']}"
        resp = await _github_request(token, "GET", "/search/code", params={"q": query})
        items = resp.json().get("items", [])
        lines = [f"- {i.get('path')} ({i.get('repository', {}).get('full_name')})" for i in items[:20]]
        return _truncate("Code search results:\n" + "\n".join(lines)) if lines else "No matches."
    if tool_name == "github_get_file":
        params = {"ref": args["ref"]} if args.get("ref") else None
        resp = await _github_request(
            token, "GET", f"/repos/{args['repo']}/contents/{args['path']}", params=params
        )
        data = resp.json()
        content = data.get("content", "")
        if data.get("encoding") == "base64" and content:
            content = base64.b64decode(content).decode("utf-8", errors="replace")
        return _truncate(content)
    if tool_name == "github_list_issues_or_prs":
        endpoint = "pulls" if args.get("type") == "pr" else "issues"
        resp = await _github_request(
            token,
            "GET",
            f"/repos/{args['repo']}/{endpoint}",
            params={"state": args.get("state", "open"), "per_page": 30},
        )
        items = resp.json()
        lines = [f"- #{i.get('number')}: {i.get('title')} ({i.get('state')})" for i in items]
        return _truncate("\n".join(lines)) if lines else "None found."
    if tool_name == "github_get_pr_diff":
        resp = await _github_request(
            token,
            "GET",
            f"/repos/{args['repo']}/pulls/{args['pr_number']}",
            accept="application/vnd.github.diff",
        )
        return _truncate(resp.text)
    if tool_name == "github_create_issue":
        resp = await _github_request(
            token,
            "POST",
            f"/repos/{args['repo']}/issues",
            json={"title": args["title"], "body": args.get("body", "")},
        )
        data = resp.json()
        return f"Created issue #{data.get('number')}: {data.get('html_url')}"
    if tool_name == "github_comment_pr":
        resp = await _github_request(
            token,
            "POST",
            f"/repos/{args['repo']}/issues/{args['pr_number']}/comments",
            json={"body": args["body"]},
        )
        data = resp.json()
        return f"Comment posted: {data.get('html_url')}"
    return f"Unknown GitHub tool: {tool_name}"
