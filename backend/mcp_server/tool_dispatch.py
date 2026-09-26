"""Tool definitions and dispatch logic for the LangGraph agent."""

import asyncio
import logging
import uuid
from typing import Any

from backend.config import get_config
from backend.mcp_server.tools.query_graph import query_graph
from backend.mcp_server.tools.search_vectors import search_vectors
from mcp.client.session import ClientSession
from mcp.client.sse import sse_client

logger = logging.getLogger(__name__)

_MCP_TOOL_CACHE: dict[str, Any] = {}  # Cache tool schemas to avoid frequent handshakes


async def get_tools(tool_settings: dict | None = None) -> list:
    """Return a list of tool definitions to bind to the LLM."""
    config = get_config()

    # Default to disabled if settings are missing
    file_search_enabled = False
    web_search_enabled = False
    run_code_enabled = False
    skills_enabled = False
    mcp_servers = []

    if tool_settings:
        file_search_enabled = tool_settings.get("file_search_enabled", False)
        if "web_search" in tool_settings and "enabled" in tool_settings["web_search"]:
            web_search_enabled = tool_settings["web_search"]["enabled"]

        run_code_enabled = tool_settings.get("run_code_enabled", False)
        skills_enabled = tool_settings.get("skills_enabled", False)
        if skills_enabled:
            mcp_servers = tool_settings.get("mcp_servers", [])

    all_tools = []

    if web_search_enabled:
        all_tools.extend(
            [
                {
                    "type": "function",
                    "function": {
                        "name": "web_browser",
                        "description": "Navigate the web to answer the user's question or perform an action.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "task": {
                                    "type": "string",
                                    "description": "The goal or task for the browser to achieve.",
                                }
                            },
                            "required": ["task"],
                        },
                    },
                },
            ]
        )

    if file_search_enabled:
        all_tools.extend(
            [
                {
                    "type": "function",
                    "function": {
                        "name": "search_vectors",
                        "description": "Search for semantically similar text chunks in the vector database.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "query_text": {
                                    "type": "string",
                                    "description": "The text to search for.",
                                },
                                "limit": {
                                    "type": ["integer", "string"],
                                    "description": f"Maximum number of results to return (default {config.default_search_limit}).",
                                },
                            },
                            "required": ["query_text"],
                        },
                    },
                },
                {
                    "type": "function",
                    "function": {
                        "name": "query_graph",
                        "description": "Query the knowledge graph starting from a specific entity.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "entity_name": {
                                    "type": "string",
                                    "description": "The name of the entity to start the traversal from.",
                                },
                                "max_hops": {
                                    "type": "integer",
                                    "description": f"Maximum number of relationship hops (default {config.default_max_hops}).",
                                },
                            },
                            "required": ["entity_name"],
                        },
                    },
                },
            ]
        )

    if web_search_enabled:
        all_tools.append(
            {
                "type": "function",
                "function": {
                    "name": "web_search",
                    "description": "Search the internet for real-time information, news, and external knowledge. Use this for general queries.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": {
                                "type": "string",
                                "description": "The search query.",
                            }
                        },
                        "required": ["query"],
                    },
                },
            }
        )
        all_tools.append(
            {
                "type": "function",
                "function": {
                    "name": "deep_research",
                    "description": "Perform a highly precise, deep web search by building a temporary knowledge graph. Use this for complex research, fact-checking, or mapping entity relationships.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": {
                                "type": "string",
                                "description": "The specific topic or claim to research.",
                            }
                        },
                        "required": ["query"],
                    },
                },
            }
        )
        all_tools.append(
            {
                "type": "function",
                "function": {
                    "name": "agentic_debate",
                    "description": "Run a multi-agent debate (STORM-like) to research, draft, and aggressively fact-check a claim using multiple AI personas. Use this for the highest possible precision fact checking.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": {
                                "type": "string",
                                "description": "The specific claim to fact check.",
                            }
                        },
                        "required": ["query"],
                    },
                },
            }
        )

    if run_code_enabled:
        all_tools.append(
            {
                "type": "function",
                "function": {
                    "name": "run_python_code",
                    "description": "Execute Python code in a secure sandbox and return the stdout and stderr.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "code": {
                                "type": "string",
                                "description": "The Python code to execute.",
                            }
                        },
                        "required": ["code"],
                    },
                },
            }
        )

    if skills_enabled and mcp_servers:
        for server in mcp_servers:
            server_name = server.get("name", "unknown")
            url = server.get("url", "")
            is_enabled = server.get("enabled", True)

            if not url or not is_enabled:
                continue

            if url in _MCP_TOOL_CACHE:
                all_tools.extend(_MCP_TOOL_CACHE[url])
                continue

            try:
                async with sse_client(url) as (read, write):  # noqa: SIM117
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        tools_res = await session.list_tools()
                        mapped_tools = []
                        for t in tools_res.tools:
                            mapped_tools.append(
                                {
                                    "type": "function",
                                    "function": {
                                        "name": f"mcp__{server_name}__{t.name}",
                                        "description": t.description
                                        or "MCP Dynamic Tool",
                                        "parameters": t.inputSchema
                                        or {"type": "object", "properties": {}},
                                    },
                                }
                            )
                        _MCP_TOOL_CACHE[url] = mapped_tools
                        all_tools.extend(mapped_tools)
            except Exception as e:
                logger.error(f"Failed to fetch tools from MCP server {url}: {e}")

    return all_tools


def _execute_single_tool(
    tool_name: str, tool_input: dict, tenant_id: str, tool_settings: dict | None = None
) -> tuple[list[Any], list[Any]]:
    """Execute a built-in Python tool."""
    from backend.config import get_config
    config = get_config()
    settings = tool_settings or {}

    if tool_name == "search_vectors":
        if not settings.get("file_search_enabled", False):

            class ErrorHit:
                def __init__(self):
                    self.id = "tool_err"
                    self.payload = {
                        "error": "Tool search_vectors is currently disabled by the user."
                    }
                    self.sources = ["System Error"]

            return [ErrorHit()], []
        limit = int(tool_input.get("limit", config.default_search_limit))
        return search_vectors(
            tool_input["query_text"], limit=limit, tenant_id=tenant_id
        ), []

    elif tool_name == "query_graph":
        if not settings.get("file_search_enabled", False):
            return [], []
        max_hops = int(tool_input.get("max_hops", config.default_max_hops))
        return [], query_graph(
            tool_input["entity_name"], max_hops=max_hops, tenant_id=tenant_id
        )

    elif tool_name == "web_search":
        web_search = settings.get("web_search", {})
        if not web_search.get("enabled", False):

            class WebSearchErrorHit:
                def __init__(self):
                    self.id = "tool_err"
                    self.payload = {
                        "error": "Tool web_search is currently disabled by the user."
                    }
                    self.sources = ["System Error"]

            return [WebSearchErrorHit()], []

        if web_search.get("high_accuracy", False):
            from backend.mcp_server.tools.deep_research import mcp_deep_research

            dr_results = mcp_deep_research(
                tool_input["query"], tenant_id=tenant_id, tool_settings=tool_settings
            )

            class DeepHit:
                def __init__(self, res):
                    self.id = res.get("id", str(uuid.uuid4()))
                    self.payload = {
                        "text": res.get("text", ""),
                        "title": "Verified Entity Context",
                        "url": res.get("sources", [""])[0]
                        if res.get("sources")
                        else "",
                    }
                    self.sources = res.get("sources", [""])

            hits = dr_results.get("results", [])
            return [DeepHit(r) for r in hits], []
        else:
            from backend.mcp_server.tools.web_search import mcp_web_search

            results = mcp_web_search(tool_input["query"], tool_settings=tool_settings)

            class WebHit:
                def __init__(self, res):
                    self.id = str(uuid.uuid4())
                    self.payload = {
                        "text": res.get("content", ""),
                        "snippet": res.get("snippet", ""),
                        "title": res.get("title", ""),
                        "url": res.get("url", ""),
                    }
                    self.sources = [res.get("url", "web")]

            return [WebHit(r) for r in results], []

    elif tool_name == "deep_research":
        web_search = settings.get("web_search", {})
        if not web_search.get("enabled", False):
            class DRErrorHit:
                def __init__(self):
                    self.id = "tool_err"
                    self.payload = {
                        "error": "Tool deep_research is currently disabled by the user."
                    }
                    self.sources = ["System Error"]
            return [DRErrorHit()], []

        from backend.mcp_server.tools.deep_research import mcp_deep_research
        
        dr_results = mcp_deep_research(tool_input["query"], tenant_id=tenant_id, tool_settings=tool_settings)
        
        class DeepResHit:
            def __init__(self, res):
                self.id = res.get("id", str(uuid.uuid4()))
                self.payload = {
                    "text": res.get("text", ""),
                    "title": "Verified Entity Context",
                    "url": res.get("sources", [""])[0] if res.get("sources") else "",
                }
                self.sources = res.get("sources", [""])

        hits = dr_results.get("results", [])
        return [DeepResHit(r) for r in hits], []

    elif tool_name == "agentic_debate":
        web_search = settings.get("web_search", {})
        if not web_search.get("enabled", False):
            class DebateErrorHit:
                def __init__(self):
                    self.id = "tool_err"
                    self.payload = {
                        "error": "Tool agentic_debate is currently disabled by the user."
                    }
                    self.sources = ["System Error"]
            return [DebateErrorHit()], []

        from backend.mcp_server.orchestrator_multi_agent import mcp_agentic_debate
        
        debate_results = mcp_agentic_debate(tool_input["query"], tenant_id=tenant_id, tool_settings=tool_settings)
        
        class DebateHit:
            def __init__(self, res):
                self.id = res.get("id", str(uuid.uuid4()))
                self.payload = {
                    "text": res.get("text", ""),
                    "title": "Agentic Debate Verified Answer",
                    "url": "",
                }
                self.sources = res.get("sources", [""])

        hits = debate_results.get("results", [])
        return [DebateHit(r) for r in hits], []

    elif tool_name == "run_python_code":
        import requests # type: ignore[import-untyped]

        try:
            resp = requests.post(
                config.code_interpreter_url,
                json={"code": tool_input["code"]},
                timeout=15,
            )
            resp.raise_for_status()
            data = resp.json()

            class CodeHit:
                def __init__(self, res):
                    self.id = "code_exec"
                    self.payload = {
                        "stdout": res.get("stdout", ""),
                        "stderr": res.get("stderr", ""),
                        "exit_code": res.get("exit_code"),
                    }
                    self.sources = ["Python Sandbox"]

            return [CodeHit(data)], []
        except Exception as e:

            class CodeErrorHit:
                def __init__(self, err):
                    self.id = "code_err"
                    self.payload = {"error": str(err)}
                    self.sources = ["Python Sandbox Error"]

            return [CodeErrorHit(e)], []

    elif tool_name == "get_current_time":
        import datetime

        class TimeHit:
            def __init__(self):
                self.id = "time"
                self.payload = {
                    "current_utc_time": datetime.datetime.now(datetime.UTC).isoformat()
                }
                self.sources = ["System Clock"]

        return [TimeHit()], []

    elif tool_name == "web_browser":
        from backend.config import get_config
        from backend.mcp_server.orchestrator import (
            _create_chat_llm,
            _request_api_key,
            _request_base_url,
            _request_model,
        )
        from backend.mcp_server.tools.web_browser import mcp_web_browser

        config = get_config()
        effective_model = _request_model.get() or config.llm_model_name
        effective_api_key = _request_api_key.get() or config.llm_api_key
        effective_base_url = _request_base_url.get() or None
        llm = _create_chat_llm(effective_model, effective_api_key, effective_base_url)

        # We need to run the async web browser tool here but this method is called within a threadpool by loop.run_in_executor
        # So we can safely use asyncio.run
        result = asyncio.run(mcp_web_browser(tool_input["task"], llm))

        class BrowserHit:
            def __init__(self, res):
                self.id = "browser_action"
                self.payload = res
                self.sources = ["Browser"]

        return [BrowserHit(result)], []

    elif tool_name == "fetch_url":
        import requests # type: ignore[import-untyped]

        try:
            resp = requests.get(tool_input["url"], timeout=10)
            resp.raise_for_status()

            class UrlHit:
                def __init__(self, text, url):
                    self.id = "url"
                    self.payload = {"content": text[:2000]}  # Truncate to save tokens
                    self.sources = [url]

            return [UrlHit(resp.text, tool_input["url"])], []
        except Exception as e:

            class UrlErrorHit:
                def __init__(self, err, url):
                    self.id = "url_err"
                    self.payload = {"error": str(err)}
                    self.sources = [url]

            return [UrlErrorHit(e, tool_input["url"])], []

    return [], []


async def _execute_mcp_tool(
    tool_name: str, tool_input: dict, tool_settings: dict
) -> tuple[list[Any], list[Any]]:
    """Execute a tool backed by an external MCP server."""
    parts = tool_name.split("__", 2)
    if len(parts) != 3:
        return [], []
    server_name = parts[1]
    actual_tool_name = parts[2]

    mcp_servers = tool_settings.get("mcp_servers", [])
    url = next(
        (s.get("url") for s in mcp_servers if s.get("name") == server_name), None
    )
    if not url:
        return [], []

    try:
        async with sse_client(url) as (read, write):  # noqa: SIM117
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool(actual_tool_name, tool_input)

                class McpHit:
                    def __init__(self, res):
                        self.id = "mcp_tool"
                        self.payload = {"content": str(res)}
                        self.sources = [f"MCP Server ({server_name})"]

                return [McpHit(result)], []
    except Exception as e:
        logger.error(f"Failed to execute MCP tool {tool_name} on {url}: {e}")

        class McpErrorHit:
            def __init__(self, err):
                self.id = "mcp_err"
                self.payload = {"error": str(err)}
                self.sources = [f"MCP Server ({server_name})"]

        return [McpErrorHit(e)], []


def _build_context_string(merged_results: list[Any]) -> str:
    """Build a formatted context string from fused results."""
    context_parts = []
    for i, res in enumerate(merged_results, 1):
        source_info = " and ".join(res.sources)
        payload_str = str(res.payload)
        context_parts.append(f"[Result {i} (from {source_info})]: {payload_str}")

    return "\n".join(context_parts)


async def execute_tools_internal(
    tool_calls: list[dict], tenant_id: str, tool_settings: dict
) -> tuple[str, list[Any]]:
    """Internal orchestration to execute tools and merge results.

    Returns a tuple of (context_str, merged_results).
    """
    from backend.retrieval.merge_rank import merge_rank

    vector_hits = []
    graph_hits = []

    for tool_call in tool_calls:
        tool_name = tool_call["name"]
        tool_input = tool_call["args"]

        logger.info(f"LangGraph Agent called tool: {tool_name} with args: {tool_input}")

        if tool_name.startswith("mcp__"):
            v_hits, g_hits = await _execute_mcp_tool(
                tool_name, tool_input, tool_settings
            )
        else:
            # Run synchronous DB calls in threadpool
            loop = asyncio.get_running_loop()
            v_hits, g_hits = await loop.run_in_executor(
                None,
                _execute_single_tool,
                tool_name,
                tool_input,
                tenant_id,
                tool_settings,
            )

        vector_hits.extend(v_hits)
        graph_hits.extend(g_hits)

    merged = merge_rank(vector_hits, graph_hits)
    context_str = _build_context_string(merged)

    if not context_str:
        context_str = "No results found."

    return context_str, merged
