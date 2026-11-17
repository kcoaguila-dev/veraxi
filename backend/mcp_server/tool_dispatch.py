"""Tool definitions and dispatch logic for the LangGraph agent."""

import asyncio
import copy
import logging
import os
import shlex
import subprocess
import tempfile
import uuid
from typing import Any

from mcp.client.session import ClientSession
from mcp.client.sse import sse_client

from backend.config import get_config
from backend.mcp_server.tools.query_graph import query_graph
from backend.mcp_server.tools.search_vectors import search_vectors

logger = logging.getLogger(__name__)

_MCP_TOOL_CACHE: dict[str, Any] = {}  # Cache tool schemas to avoid frequent handshakes


async def get_tools(tool_settings: dict | None = None, tenant_id: str | None = None) -> list:
    """Return a list of tool definitions to bind to the LLM."""
    config = get_config()

    # Default to disabled if settings are missing
    file_search_enabled = False
    web_search_enabled = False
    run_code_enabled = False

    if tool_settings:
        file_search_enabled = tool_settings.get("file_search_enabled", False)
        if "web_search" in tool_settings and "enabled" in tool_settings["web_search"]:
            web_search_enabled = tool_settings["web_search"]["enabled"]

        run_code_enabled = tool_settings.get("run_code_enabled", False)

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

    # Inject native Android tools passed from the frontend
    if tool_settings and "agent_tools" in tool_settings:
        all_tools.extend(tool_settings["agent_tools"])

    if file_search_enabled:
        all_tools.extend(
            [
                {
                    "type": "function",
                    "function": {
                        "name": "search_vectors",
                        "description": (
                            "Search for semantically similar text chunks in the vector database. "
                            "Cite retrieved evidence using inline bracketed numbers [1], [2] or [Document Title]."
                        ),
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
                        "description": (
                            "Query the knowledge graph starting from a specific entity. "
                            "Cite referenced entities using inline brackets [Entity Name]."
                        ),
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
        # Repo X-Ray code-graph tools read the same tenant graph as
        # query_graph, so they share its file_search gate.
        from backend.mcp_server.tools.code_tools import (
            tool_schemas as _code_tool_schemas,
        )
        from backend.mcp_server.tools.vuln_tools import (
            tool_schemas as _vuln_tool_schemas,
        )

        all_tools.extend(_code_tool_schemas())
        all_tools.extend(_vuln_tool_schemas())

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
                    "name": "ephemeral_web_rag",
                    "description": "Crawl live web URLs, dynamically ingest them into an ephemeral sandboxed knowledge graph and vector space, and return fused RRF facts.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": {
                                "type": "string",
                                "description": "The specific topic or claim to research on the web.",
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

    # create_office_artifact is always available, unlike run_python_code:
    # it executes nothing, makes no external calls, and costs nothing —
    # it only validates a document spec against the deterministic
    # exporters in backend/services/office_export.py and hands back a
    # JSON block. Gating it behind a settings toggle would just make
    # "make me a deck / spreadsheet" fail unpredictably.
    all_tools.append(
        {
            "type": "function",
            "function": {
                "name": "create_office_artifact",
                "description": (
                    "Create a downloadable Office/PDF document (report, "
                    "spreadsheet, or slide deck) from a structured spec or "
                    "Markdown/CSV content. The document is validated "
                    "server-side; the tool returns a fenced ```json block "
                    "that you must include verbatim in your reply — it "
                    "becomes the downloadable file card. Use this whenever "
                    "the user asks for a document, spreadsheet, budget, "
                    "slide deck, or PDF file. For spreadsheets, cell strings "
                    "starting with '=' are stored as live Excel formulas "
                    "(e.g. '=SUM(B2:B5)'). Provide spec OR content, not both."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "format": {
                            "type": "string",
                            "enum": ["pdf", "docx", "xlsx", "pptx"],
                            "description": "The file format to produce.",
                        },
                        "title": {
                            "type": "string",
                            "description": "The document title.",
                        },
                        "spec": {
                            "type": "object",
                            "description": (
                                "Structured spec. pptx: {\"slides\": [{\"title\": str, "
                                "\"subtitle\": str (optional), \"bullets\": [str] (optional), "
                                "\"table\": {\"headers\": [str], \"rows\": [[...]]} (optional), "
                                "\"notes\": str (optional), \"theme\": \"dark\"|\"light\" (optional), "
                                "\"accent_color\": \"#RRGGBB\" (optional)}]}. "
                                "xlsx: {\"sheets\": [{\"name\": str, \"headers\": [str], "
                                "\"rows\": [[...]]}]}. docx: {\"sections\": [{\"heading\": str, "
                                "\"level\": 1-3, \"paragraphs\": [str], \"bullets\": [str], "
                                "\"table\": {\"headers\": [...], \"rows\": [[...]]}}]}. "
                                "pdf accepts any of these shapes."
                            ),
                        },
                        "content": {
                            "type": "string",
                            "description": (
                                "Document body instead of a spec: Markdown "
                                "(headings, lists, tables; for pptx, separate "
                                "slides with '---' lines) or CSV when "
                                "content_type is 'csv'. Best for prose documents."
                            ),
                        },
                        "content_type": {
                            "type": "string",
                            "enum": ["markdown", "csv"],
                            "description": "How to parse content (default markdown).",
                        },
                    },
                    "required": ["format", "title"],
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

    if tool_settings and tool_settings.get("sandbox_enabled"):
        all_tools.extend(_sandbox_tool_definitions())

    # External MCP tools come from the hardened client manager: stored
    # tenant integrations first (no skills_enabled gate), legacy
    # tool_settings servers as fallback (legacy gate preserved inside
    # the manager). Schemas are tenant-cached and capped.
    try:
        from backend.services.mcp_client_manager import get_external_tools

        all_tools.extend(await get_external_tools(tenant_id, tool_settings))
    except Exception as e:
        logger.error(f"Failed to fetch external MCP tools: {e}")

    # Curated GitHub connector tools (only when the tenant has an
    # active GitHub integration; the registrar no-ops otherwise).
    try:
        from backend.mcp_server.tools.github_tools import get_github_tools

        all_tools.extend(await get_github_tools(tenant_id, tool_settings))
    except Exception as e:
        logger.error(f"Failed to fetch GitHub connector tools: {e}")

    # Imported OpenAPI actions (only when the tenant has enabled
    # OpenAPI integrations; the registrar no-ops otherwise).
    try:
        from backend.services.openapi_importer import get_openapi_tools

        all_tools.extend(await get_openapi_tools(tenant_id, tool_settings))
    except Exception as e:
        logger.error(f"Failed to fetch OpenAPI action tools: {e}")

    return all_tools


_OFFICE_ARTIFACT_FORMATS = ("pdf", "docx", "xlsx", "pptx")
_OFFICE_ARTIFACT_CONTENT_TYPES = ("markdown", "csv")


def _build_office_artifact(tool_input: dict) -> dict:
    """Validate a ``create_office_artifact`` call and build its block.

    Validation *is* building: the supplied spec/content is run through
    the pure deterministic builders in
    :mod:`backend.services.office_export` (nothing is executed — the
    builders only parse and render). On success returns a dict with
    the canonical ``block`` — a fenced ```json envelope in the exact
    shape ``POST /api/artifacts/export`` accepts with
    ``content_type="json"`` and the Flutter artifact panel exports —
    plus the produced file's ``size_bytes``. On any problem returns
    ``{"error": ...}`` with a message the LLM can act on and retry;
    this function never raises, so a bad document request can never
    kill the chat loop.
    """
    import json

    from backend.routes.artifacts import MAX_CODE_CHARS, MAX_TITLE_CHARS

    fmt = tool_input.get("format")
    if fmt not in _OFFICE_ARTIFACT_FORMATS:
        return {
            "error": (
                "format must be one of "
                f"{', '.join(_OFFICE_ARTIFACT_FORMATS)}; got {fmt!r}."
            )
        }

    title = tool_input.get("title")
    if not isinstance(title, str) or not title.strip():
        return {"error": "title is required and must be a non-empty string."}
    title = title.strip()
    if len(title) > MAX_TITLE_CHARS:
        return {
            "error": f"title is too long (max {MAX_TITLE_CHARS} characters)."
        }

    spec = tool_input.get("spec")
    content = tool_input.get("content")
    content_type = tool_input.get("content_type") or "markdown"

    if spec is not None and not isinstance(spec, dict):
        return {"error": "spec must be a JSON object (slides / sheets / sections)."}
    if spec is None and not (isinstance(content, str) and content.strip()):
        return {
            "error": (
                "Provide either a structured spec or Markdown/CSV content "
                "for the document."
            )
        }
    if content_type not in _OFFICE_ARTIFACT_CONTENT_TYPES:
        return {
            "error": (
                "content_type must be one of "
                f"{', '.join(_OFFICE_ARTIFACT_CONTENT_TYPES)}; got {content_type!r}."
            )
        }
    if spec is not None and len(json.dumps(spec)) > MAX_CODE_CHARS:
        return {
            "error": f"spec is too large (max {MAX_CODE_CHARS} characters)."
        }
    if isinstance(content, str) and len(content) > MAX_CODE_CHARS:
        return {
            "error": f"content is too large (max {MAX_CODE_CHARS} characters)."
        }

    from backend.services.office_export import (
        export_docx,
        export_pdf,
        export_pptx,
        export_xlsx,
        spec_to_markdown,
    )

    try:
        if spec is not None:
            if fmt == "pdf":
                # The PDF builder consumes content, not specs: render
                # the spec to Markdown first, like the export route.
                data = export_pdf(title, spec_to_markdown(spec), "markdown")
            elif fmt == "docx":
                data = export_docx(title, "", spec)
            elif fmt == "xlsx":
                data = export_xlsx(title, "", spec)
            else:
                data = export_pptx(title, "", spec)
            envelope: dict[str, Any] = {**spec, "format": fmt, "title": title}
        else:
            if fmt == "pdf":
                data = export_pdf(title, content, content_type)
            elif fmt == "docx":
                data = export_docx(title, content)
            elif fmt == "xlsx":
                data = export_xlsx(title, content)
            else:
                data = export_pptx(title, content)
            envelope = {
                "format": fmt,
                "title": title,
                "content_type": content_type,
                "content": content,
            }
    except ValueError as e:
        return {"error": f"Invalid document spec: {e}"}
    except Exception as e:
        import sentry_sdk

        sentry_sdk.capture_exception(e)
        logger.error(f"create_office_artifact failed to build {fmt}: {e}")
        return {"error": f"Could not build the document: {e}"}

    block = "```json\n" + json.dumps(envelope, indent=2, ensure_ascii=False) + "\n```"
    return {
        "format": fmt,
        "title": title,
        "size_bytes": len(data),
        "block": block,
    }


def _execute_single_tool(
    tool_name: str, tool_input: dict, tenant_id: str, tool_settings: dict | None = None
) -> tuple[list[Any], list[Any]]:
    """Execute a built-in Python tool."""
    from backend.config import get_config

    config = get_config()
    settings = tool_settings or {}

    # 1. Native Android tools (executed locally on the phone, backend just acknowledges them)
    if tool_name in ["read_file", "write_file", "list_files", "run_shell", "open_app"]:

        class ClientToolHit:
            def __init__(self):
                self.id = "client_tool"
                self.payload = {"status": "Tool delegated to Android client"}
                self.sources = ["Android Client"]

        return [ClientToolHit()], []

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

    elif tool_name in ("code_symbol", "code_impact", "code_overview"):
        if not settings.get("file_search_enabled", False):
            return [], []

        class CodeHit:
            def __init__(self, res: dict) -> None:
                self.id = "code_graph"
                self.payload = res
                self.sources = ["Repo X-Ray"]

        from backend.mcp_server.tools.code_tools import (
            code_impact,
            code_overview,
            code_symbol,
        )

        if tool_name == "code_symbol":
            result = code_symbol(tool_input["name"], tenant_id=tenant_id)
        elif tool_name == "code_impact":
            result = code_impact(
                tool_input["symbol"],
                tenant_id=tenant_id,
                max_depth=int(tool_input.get("max_depth", 3)),
            )
        else:
            result = code_overview(
                tenant_id=tenant_id,
                path_prefix=tool_input.get("path_prefix"),
            )
        return [CodeHit(result)], []

    elif tool_name == "vuln_report":
        if not settings.get("file_search_enabled", False):
            return [], []

        class VulnHit:
            def __init__(self, res: dict) -> None:
                self.id = "vuln_intel"
                self.payload = res
                self.sources = ["Vuln Intel"]

        from backend.mcp_server.tools.vuln_tools import (
            vuln_report as _vuln_report,
        )

        result = _vuln_report(
            tenant_id=tenant_id,
            dependencies=tool_input.get("dependencies"),
            repo_path=tool_input.get("repo_path"),
        )
        return [VulnHit(result)], []

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
            from backend.mcp_server.tools.ephemeral_web_rag import (
                mcp_ephemeral_web_rag,
            )

            dr_results = mcp_ephemeral_web_rag(
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

    elif tool_name == "ephemeral_web_rag":
        web_search = settings.get("web_search", {})
        if not web_search.get("enabled", False):

            class DRErrorHit:
                def __init__(self):
                    self.id = "tool_err"
                    self.payload = {
                        "error": f"Tool {tool_name} is currently disabled by the user."
                    }
                    self.sources = ["System Error"]

            return [DRErrorHit()], []

        from backend.mcp_server.tools.ephemeral_web_rag import mcp_ephemeral_web_rag

        dr_results = mcp_ephemeral_web_rag(
            tool_input["query"], tenant_id=tenant_id, tool_settings=tool_settings
        )

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

        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        if loop and loop.is_running():
            import concurrent.futures

            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                debate_results = pool.submit(
                    asyncio.run,
                    mcp_agentic_debate(
                        tool_input["query"],
                        tenant_id=tenant_id,
                        tool_settings=tool_settings,
                    ),
                ).result()
        else:
            debate_results = asyncio.run(
                mcp_agentic_debate(
                    tool_input["query"],
                    tenant_id=tenant_id,
                    tool_settings=tool_settings,
                )
            )

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
        from backend.mcp_server.tools.run_code import execute_python_code

        code_to_run = tool_input.get("code", "")
        data = None
        source_label = "Python Sandbox"

        if getattr(config, "code_interpreter_url", None):
            try:
                import requests  # type: ignore[import-untyped]

                resp = requests.post(
                    config.code_interpreter_url,
                    json={"code": code_to_run},
                    timeout=15,
                )
                resp.raise_for_status()
                data = resp.json()
                source_label = "Python Sandbox (Remote)"
            except Exception:
                # Fallback to zero-trust local execution
                data = None

        if data is None:
            try:
                data = execute_python_code(code_to_run)
                source_label = "Python Sandbox (Zero-Trust)"
            except Exception as e:

                class CodeErrorHit:
                    def __init__(self, err: Exception) -> None:
                        self.id = "code_err"
                        self.payload = {"error": str(err)}
                        self.sources = ["Python Sandbox Error"]

                return [CodeErrorHit(e)], []

        class CodeHit:
            def __init__(self, res: dict[str, Any], src: str) -> None:
                self.id = "code_exec"
                self.payload = {
                    "stdout": res.get("stdout", ""),
                    "stderr": res.get("stderr", ""),
                    "exit_code": res.get("exit_code"),
                }
                self.sources = [src]

        return [CodeHit(data, source_label)], []

    elif tool_name == "create_office_artifact":
        result = _build_office_artifact(tool_input)

        if "error" in result:

            class OfficeErrorHit:
                def __init__(self, msg: str) -> None:
                    self.id = "office_err"
                    self.payload = {"error": msg}
                    self.sources = ["Office Artifact Error"]

            return [OfficeErrorHit(result["error"])], []

        block = result["block"]

        class OfficeHit:
            def __init__(self, res: dict[str, Any]) -> None:
                self.id = "office_artifact"
                self.payload = {
                    "kind": "office_artifact",
                    "format": res["format"],
                    "title": res["title"],
                    "artifact_block": block,
                    "text": (
                        f"Created and validated a {res['format']} document "
                        f"titled '{res['title']}' ({res['size_bytes']} bytes "
                        "when exported). Include the following block in your "
                        "reply EXACTLY as-is — do not edit, reformat, or add "
                        "anything inside it — with only a brief sentence "
                        f"around it:\n\n{block}"
                    ),
                }
                self.sources = ["Office Artifact"]

        return [OfficeHit(result)], []

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
        import requests  # type: ignore[import-untyped]

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


SANDBOX_TOOL_NAMES = {
    "sandbox_exec", "sandbox_read_file", "sandbox_write_file", "sandbox_diff",
}

_sandbox_manager_override = None


def set_sandbox_manager(manager) -> None:
    """Inject the SandboxManager used by sandbox tools (test seam)."""
    global _sandbox_manager_override
    _sandbox_manager_override = manager


def _sandbox_tool_definitions() -> list:
    """The exactly-four minimal sandbox tools (no MCP context bloat)."""
    return [
        {
            "type": "function",
            "function": {
                "name": "sandbox_exec",
                "description": "Run a shell command inside the tenant's isolated coding sandbox (git, pytest, flutter test, rg, ...). Output streams back live.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "command": {"type": "string", "description": "The shell command to run."},
                        "cwd": {"type": "string", "description": "Optional working directory inside the sandbox."},
                    },
                    "required": ["command"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "sandbox_read_file",
                "description": "Read a file inside the coding sandbox.",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "sandbox_write_file",
                "description": "Write a file inside the coding sandbox.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string"},
                        "content": {"type": "string"},
                    },
                    "required": ["path", "content"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "sandbox_diff",
                "description": "Return the current git diff inside the coding sandbox for review.",
                "parameters": {"type": "object", "properties": {}},
            },
        },
    ]


class SandboxHit:
    """Result of an executed sandbox tool call.

    The payload carries the collected ``sandbox_events`` (stdout /
    stderr chunks plus the final exit event) so the existing SSE chat
    stream can render them live, alongside a plain ``content`` string.
    """

    def __init__(self, payload: dict):
        self.id = "sandbox_tool"
        self.payload = payload
        self.sources = ["Sandbox"]


class SandboxApprovalHit:
    """Sandbox tool call paused for user approval.

    Carries both the existing ``tool_confirmation_required`` payload
    (the confirm-tool mechanism) and an ``approval_required`` payload
    naming the tool, per the sandbox autonomy policy.
    """

    def __init__(self, tool_name: str, tool_input: dict, autonomy_mode: str):
        self.id = "tool_confirmation"
        approval = {
            "tool_name": tool_name,
            "args": tool_input,
            "autonomy_mode": autonomy_mode,
            "message": (
                f"{tool_name} needs the user's approval before it runs "
                f"(autonomy mode: {autonomy_mode})."
            ),
        }
        self.payload = {
            "tool_confirmation_required": dict(approval),
            "approval_required": dict(approval),
        }
        self.sources = ["Tool Confirmation"]


def _resolve_sandbox_manager(tool_settings: dict):
    manager = (tool_settings or {}).get("sandbox_manager") or _sandbox_manager_override
    if manager is not None:
        return manager
    from backend.sandbox.manager import get_default_manager

    return get_default_manager()


async def _execute_sandbox_tool(tc: dict, tenant_id: str, tool_settings: dict) -> list:
    """Execute one sandbox_* tool call through the SandboxManager."""
    from backend.sandbox.policy import classify_command, requires_approval

    t_name = tc.get("name", "")
    t_input = tc.get("args", {}) or {}
    manager = _resolve_sandbox_manager(tool_settings)
    try:
        settings, _secrets, _row = manager.load_tenant_config(tenant_id)
        autonomy_mode = str(settings.get("autonomy_mode") or "auto_read_test")
    except Exception as e:
        logger.error(f"Failed to load sandbox config for {tenant_id}: {e}")
        autonomy_mode = str((tool_settings or {}).get("sandbox_autonomy_mode") or "auto_read_test")

    is_write = t_name == "sandbox_write_file"
    command = None
    if t_name == "sandbox_exec":
        command = str(t_input.get("command") or "")
        is_write = classify_command(command) == "mutating"

    if requires_approval(autonomy_mode, command, is_write=is_write) and not _tool_call_confirmed(tc, tool_settings):
        try:
            manager.record_approval_request("", {"tool_name": t_name, "args": t_input})
        except Exception as e:
            logger.debug(f"Failed to record sandbox approval request: {e}")
        return [SandboxApprovalHit(t_name, t_input, autonomy_mode)]

    chat_id = (tool_settings or {}).get("chat_id") or (tool_settings or {}).get("thread_id")
    try:
        info = await manager.get_or_create_session(tenant_id, chat_id=chat_id)
        provider = manager.provider_for(info.session_id)
        events: list[dict] = []
        exit_code = None
        if t_name == "sandbox_exec":
            stdout_parts, stderr_parts = [], []
            async for event in provider.exec_command(
                info.session_id, command or "", cwd=t_input.get("cwd"),
                timeout_sec=int(t_input.get("timeout_sec") or 120),
            ):
                events.append(event.to_dict())
                if event.kind == "stdout":
                    stdout_parts.append(event.data)
                elif event.kind == "stderr":
                    stderr_parts.append(event.data)
                elif event.kind == "exit":
                    exit_code = event.exit_code
            content = "".join(stdout_parts)
            if stderr_parts:
                content += "\n[stderr]:\n" + "".join(stderr_parts)
            content += f"\n[exit_code]: {exit_code}"
        elif t_name == "sandbox_read_file":
            content = await provider.read_file(info.session_id, str(t_input.get("path") or ""))
        elif t_name == "sandbox_write_file":
            await provider.write_file(
                info.session_id, str(t_input.get("path") or ""), str(t_input.get("content") or "")
            )
            content = f"Wrote {t_input.get('path')}"
        elif t_name == "sandbox_diff":
            content = await provider.get_diff(info.session_id)
        else:  # pragma: no cover - guarded by SANDBOX_TOOL_NAMES
            content = ""
        return [SandboxHit({
            "content": content,
            "sandbox_events": events,
            "sandbox_stdout": [e["data"] for e in events if e.get("type") == "stdout"],
            "sandbox_stderr": [e["data"] for e in events if e.get("type") == "stderr"],
            "exit_code": exit_code,
            "session_id": info.session_id,
            "tool": t_name,
        })]
    except Exception as e:
        logger.error(f"Sandbox tool {t_name} failed: {e}")
        return [SandboxHit({"content": f"Sandbox error: {e}", "error": str(e), "tool": t_name, "sandbox_events": []})]


class ToolConfirmationHit:
    """Result for a mutating external tool call awaiting user approval.

    The payload carries a ``tool_confirmation_required`` object the
    client renders as an Approve/Reject card; the gated tool is NOT
    executed. Approval re-enters dispatch with the tool name listed in
    ``tool_settings["confirmed_tool_names"]`` (see
    ``POST /api/chat/confirm-tool``).
    """

    def __init__(self, tool_name: str, tool_input: dict):
        self.id = "tool_confirmation"
        self.payload = {
            "tool_confirmation_required": {
                "tool_name": tool_name,
                "args": tool_input,
                "message": (
                    f"{tool_name} changes external state and needs the "
                    "user's approval before it runs."
                ),
            }
        }
        self.sources = ["Tool Confirmation"]


def _tool_requires_confirmation(tool_name: str) -> bool:
    """True for mutating external tools gated behind user approval."""
    try:
        from backend.mcp_server.tools.github_tools import (
            requires_confirmation as github_requires,
        )

        if github_requires(tool_name):
            return True
    except Exception as e:
        logger.error(f"GitHub confirmation registry unavailable: {e}")
    return False


def _tool_call_confirmed(tc: dict, tool_settings: dict) -> bool:
    if tc.get("confirmed") is True:
        return True
    confirmed = (tool_settings or {}).get("confirmed_tool_names") or []
    return tc.get("name", "") in confirmed


class McpErrorHit:
    def __init__(self, err: Any, server_name: str = "External"):
        self.id = "mcp_err"
        self.payload = {"error": str(err)}
        self.sources = [f"MCP Server ({server_name})"]


class McpHit:
    def __init__(self, res: Any, diff: str, server_name: str = "External"):
        self.id = "mcp_tool"
        self.payload = {"content": str(res) + diff}
        self.sources = [f"MCP Server ({server_name})"]


async def _execute_mcp_tool(
    tool_name: str,
    tool_input: dict,
    tool_settings: dict,
    tenant_id: str | None = None,
) -> tuple[list[Any], list[Any]]:
    """Execute a tool backed by an external MCP server."""
    parts = tool_name.split("__", 2)
    if len(parts) != 3:
        return [], []
    server_name = parts[1]
    actual_tool_name = parts[2]

    # Stored integrations (and legacy servers without the worktree
    # contract) execute through the hardened client manager: SSRF
    # re-validation, transport fallback, timeouts, tenant cache.
    legacy_servers = tool_settings.get("mcp_servers", []) or []
    legacy_cfg = next(
        (s for s in legacy_servers if s.get("name") == server_name), None
    )
    if not (legacy_cfg and legacy_cfg.get("supports_worktree")):
        try:
            from backend.services import mcp_client_manager as mcp_manager

            specs = mcp_manager.load_server_specs(tenant_id, tool_settings)
            spec = mcp_manager.find_spec(specs, server_name)
            if spec is not None:
                result = await mcp_manager.call_tool(
                    spec, tenant_id or "", tool_name, tool_input
                )
                return [McpHit(result, "", server_name)], []
        except Exception as e:
            logger.error(f"Failed to execute MCP tool {tool_name}: {e}")
            return [McpErrorHit(e, server_name)], []

    mcp_servers = tool_settings.get("mcp_servers", [])
    server_config = next((s for s in mcp_servers if s.get("name") == server_name), None)
    if not server_config or not server_config.get("url"):
        return [], []

    url = server_config["url"]

    worktree_path = None
    branch_name = None
    supports_worktree = server_config.get("supports_worktree", False)

    # Only apply worktree wrapper to servers with an explicit shared-filesystem contract
    if supports_worktree:
        branch_name = f"veraxi_agent_{uuid.uuid4().hex[:8]}"
        worktree_path = os.path.join(tempfile.gettempdir(), branch_name)

    preserve_worktree = False
    try:
        if supports_worktree and worktree_path and branch_name:
            tool_input = copy.deepcopy(tool_input)
            # Spin up a temporary Git Worktree isolated from the main branch
            proc = await asyncio.create_subprocess_exec(
                "git",
                "worktree",
                "add",
                "-b",
                branch_name,
                str(worktree_path),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()
            if proc.returncode != 0:
                raise subprocess.CalledProcessError(
                    proc.returncode or 1, "git worktree add", stdout, stderr
                )

            # Rewrite tool_input generically to force execution in the worktree
            # For shell commands (e.g. command)
            if "command" in tool_input:
                cmd = tool_input["command"]
                if ".." in cmd or " /" in cmd or cmd.startswith("/"):
                    return [
                        McpErrorHit(
                            ValueError(
                                "Commands that can address paths outside the worktree are prohibited"
                            ),
                            server_name,
                        )
                    ], []
                tool_input["command"] = f"cd {shlex.quote(worktree_path)} && " + cmd
            # For file system commands (e.g. path, filepath, file)
            for path_key in ["path", "filepath", "file", "dir", "directory"]:
                if (
                    path_key in tool_input
                    and isinstance(tool_input[path_key], str)
                    and not tool_input[path_key].startswith(worktree_path)
                ):
                    input_path = tool_input[path_key]
                    # Force it to be relative to the worktree path if it was relative or absolute
                    if os.path.isabs(input_path):
                        current_cwd = os.getcwd()
                        if not input_path.startswith(current_cwd):
                            return [
                                McpErrorHit(
                                    ValueError(
                                        f"Absolute path {input_path} is outside the allowed checkout boundary"
                                    ),
                                    server_name,
                                )
                            ], []
                        rel_path = os.path.relpath(input_path, current_cwd)
                        tool_input[path_key] = os.path.join(worktree_path, rel_path)
                    else:
                        if input_path.startswith(".."):
                            return [
                                McpErrorHit(
                                    ValueError(
                                        f"Path {input_path} escapes the allowed checkout boundary"
                                    ),
                                    server_name,
                                )
                            ], []
                        tool_input[path_key] = os.path.join(worktree_path, input_path)

        async with sse_client(url) as (read, write):  # noqa: SIM117
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool(actual_tool_name, tool_input)

                diff_output = ""
                if supports_worktree and worktree_path:
                    try:
                        diff_proc = await asyncio.create_subprocess_exec(
                            "git",
                            "diff",
                            cwd=worktree_path,
                            stdout=asyncio.subprocess.PIPE,
                            stderr=asyncio.subprocess.PIPE,
                        )
                        diff_stdout, diff_stderr = await diff_proc.communicate()
                        if diff_proc.returncode != 0:
                            preserve_worktree = True
                            logger.error(
                                f"Git diff failed: {diff_stderr.decode('utf-8')}"
                            )
                            return [
                                McpErrorHit(
                                    RuntimeError(
                                        f"Git diff failed in worktree. Preserving worktree at {worktree_path}"
                                    ),
                                    server_name,
                                )
                            ], []
                        diff_text = diff_stdout.decode("utf-8") if diff_stdout else ""
                        if diff_text:
                            diff_output = "\n\n[Git Worktree Diff]:\n" + diff_text
                    except Exception as e:
                        preserve_worktree = True
                        logger.error(f"Failed to get git diff: {e}")
                        return [
                            McpErrorHit(
                                RuntimeError(
                                    f"Exception during git diff: {e}. Preserving worktree at {worktree_path}"
                                ),
                                server_name,
                            )
                        ], []

                return [McpHit(result, diff_output, server_name)], []
    except Exception as e:
        logger.error(f"Failed to execute MCP tool {tool_name} on {url}: {e}")

        err_msg = str(e)
        if supports_worktree and worktree_path:
            preserve_worktree = True
            err_msg += f" (Worktree preserved at {worktree_path} for recovery)"

        return [McpErrorHit(err_msg, server_name)], []
    finally:
        if (
            supports_worktree
            and worktree_path
            and os.path.exists(worktree_path)
            and not preserve_worktree
        ):
            try:
                proc1 = await asyncio.create_subprocess_exec(
                    "git",
                    "worktree",
                    "remove",
                    "--force",
                    str(worktree_path),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                await proc1.communicate()
                proc2 = await asyncio.create_subprocess_exec(
                    "git",
                    "branch",
                    "-D",
                    str(branch_name),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                await proc2.communicate()
            except Exception as e:
                logger.error(f"Failed to cleanup git worktree: {e}")


def _extract_primary_query(tool_calls: list[dict]) -> str | None:
    for tc in tool_calls:
        args = tc.get("args", {})
        for key in ("query_text", "query", "entity_name"):
            val = args.get(key)
            if val and isinstance(val, str) and val.strip():
                return val.strip()
    return None


def _build_context_string(merged_results: list[Any]) -> str:
    """Build a formatted context string from fused results."""
    context_parts = []
    for i, res in enumerate(merged_results, 1):
        raw_sources = getattr(res, "sources", ["retrieval"])
        source_info = " and ".join(raw_sources) if isinstance(raw_sources, list) else str(raw_sources)
        meta_tags = [f"from {source_info}"]
        if isinstance(res.payload, dict):
            doc_source = res.payload.get("source") or res.payload.get("relation_source")
            if doc_source and doc_source != "unknown":
                meta_tags.append(f"source: {doc_source}")
            if res.payload.get("page_number") is not None:
                meta_tags.append(f"page: {res.payload['page_number']}")
            if res.payload.get("breadcrumb"):
                meta_tags.append(f"section: {res.payload['breadcrumb']}")
            if res.payload.get("is_table"):
                meta_tags.append("type: table")
            if res.payload.get("bbox"):
                meta_tags.append(f"bbox: {res.payload['bbox']}")
            if res.payload.get("last_confirmed_at"):
                meta_tags.append(f"confirmed_at: {res.payload['last_confirmed_at']}")
        header = ", ".join(meta_tags)
        payload_str = str(res.payload)
        context_parts.append(f"[Result {i} ({header})]: {payload_str}")

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
    telemetry_hits = []

    async def _dispatch_single_tool(tc: dict) -> tuple[list[Any], list[Any], list[Any]]:
        t_name = tc.get("name", "")
        t_input = tc.get("args", {})
        logger.info(f"LangGraph Agent called tool: {t_name} with args: {t_input}")

        if _tool_requires_confirmation(t_name) and not _tool_call_confirmed(
            tc, tool_settings
        ):
            return [], [], [ToolConfirmationHit(t_name, t_input)]
        if t_name in SANDBOX_TOOL_NAMES:
            s_hits = await _execute_sandbox_tool(tc, tenant_id, tool_settings)
            return [], [], s_hits
        if t_name.startswith("mcp__"):
            m_hits, _ = await _execute_mcp_tool(
                t_name, t_input, tool_settings, tenant_id
            )
            return [], [], m_hits
        if t_name.startswith("github_"):
            from backend.mcp_server.tools.github_tools import execute_github_tool

            result_text = await execute_github_tool(t_name, t_input, tenant_id)
            return [], [], [McpHit(result_text, "", "GitHub")]
        if t_name.startswith("api__"):
            from backend.services.openapi_importer import (
                execute_openapi_tool,
                openapi_requires_confirmation,
            )

            if await openapi_requires_confirmation(
                tenant_id, t_name
            ) and not _tool_call_confirmed(tc, tool_settings):
                return [], [], [ToolConfirmationHit(t_name, t_input)]
            result_text = await execute_openapi_tool(t_name, t_input, tenant_id)
            return [], [], [McpHit(result_text, "", "OpenAPI")]
        else:
            loop = asyncio.get_running_loop()
            v, g = await loop.run_in_executor(
                None,
                _execute_single_tool,
                t_name,
                t_input,
                tenant_id,
                tool_settings,
            )
            return v, g, []

    tool_results = await asyncio.gather(
        *[_dispatch_single_tool(tc) for tc in tool_calls]
    )
    for v, g, t in tool_results:
        vector_hits.extend(v)
        graph_hits.extend(g)
        telemetry_hits.extend(t)

    primary_query = _extract_primary_query(tool_calls)
    if vector_hits and not graph_hits and (tool_settings or {}).get("file_search_enabled", False):
        from backend.config import get_config
        from backend.mcp_server.tools.query_graph import (
            query_graph,
            seed_graph_hits_from_vectors,
        )

        config = get_config()
        loop = asyncio.get_running_loop()
        seeded_graph = await loop.run_in_executor(
            None,
            seed_graph_hits_from_vectors,
            vector_hits,
            primary_query or "",
            config.default_max_hops,
            tenant_id,
            3,
            query_graph,
        )
        graph_hits.extend(seeded_graph)

    merged_docs = merge_rank(vector_hits, graph_hits, query_text=primary_query)
    merged = telemetry_hits + merged_docs

    context_sections = []

    if telemetry_hits:
        telemetry_blocks = []
        for hit in telemetry_hits:
            sources = " and ".join(getattr(hit, "sources", ["External Tool"]))
            content = (
                hit.payload.get("content", str(hit.payload))
                if isinstance(hit.payload, dict)
                else str(hit.payload)
            )
            telemetry_blocks.append(f"[{sources}]:\n{content}")
        context_sections.append(
            "[EXTERNAL TELEMETRY & ACTIONS]:\n" + "\n\n".join(telemetry_blocks)
        )

    if merged_docs:
        narrative_str = _build_context_string(merged_docs)
        if narrative_str and narrative_str != "No results found.":
            context_sections.append(
                "[GROUNDED KNOWLEDGE GRAPH & VECTOR CONTEXT]:\n" + narrative_str
            )

    context_str = (
        "\n\n".join(context_sections) if context_sections else "No results found."
    )
    return context_str, merged
