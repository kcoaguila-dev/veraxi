import json

import sentry_sdk
from backend.mcp_server.context import tenant_context
from backend.mcp_server.tools.get_schema import get_graph_schema
from backend.mcp_server.tools.get_stats import get_database_stats
from backend.prompts import CRAG_ORCHESTRATOR_PROMPT, INGEST_KNOWLEDGE_PROMPT
from mcp.server import Server
from mcp.types import (
    CallToolResult,
    GetPromptResult,
    ListPromptsResult,
    ListResourcesResult,
    ListToolsResult,
    Prompt,
    PromptMessage,
    ReadResourceResult,
    Resource,
    TextContent,
    TextResourceContents,
)


async def handle_list_resources(ctx, params) -> ListResourcesResult:
    """List available resources."""
    return ListResourcesResult(resources=[
        Resource(
            uri="veraxi://schema",
            name="Database Schema",
            description="The current schema of node labels and relationship types in the Neo4j Graph.",
            mimeType="application/json",
        ),
        Resource(
            uri="veraxi://stats",
            name="Database Statistics",
            description="Live counts of nodes, vectors, and relationships for the current tenant.",
            mimeType="application/json",
        )
    ])

async def handle_read_resource(ctx, params) -> ReadResourceResult:
    """Read a specific resource."""
    uri = params.uri
    tenant_id = tenant_context.get()
    
    if uri == "veraxi://schema":
        results = get_graph_schema()
        return ReadResourceResult(contents=[TextResourceContents(uri=uri, mimeType="application/json", text=json.dumps(results))])
    elif uri == "veraxi://stats":
        return ReadResourceResult(contents=[TextResourceContents(uri=uri, mimeType="application/json", text=json.dumps(get_database_stats(tenant_id=tenant_id)))])
    else:
        raise ValueError(f"Resource not found: {uri}")

async def handle_list_prompts(ctx, params) -> ListPromptsResult:
    """List available prompts."""
    return ListPromptsResult(prompts=[
        Prompt(
            name="ingest_knowledge",
            description="Provides strict instructions to the Host AI on how to read source material and construct GraphRAG structures.",
            arguments=[]
        ),
        Prompt(
            name="crag_orchestrator",
            description="Instructs the Host AI to act as a Corrective Retrieval Augmented Generation orchestrator, combining internal database retrieval with live web search.",
            arguments=[]
        )
    ])

async def handle_get_prompt(ctx, params) -> GetPromptResult:
    """Get a specific prompt."""
    name = params.name
    if name == "ingest_knowledge":
        return GetPromptResult(
            description="",
            messages=[
                PromptMessage(
                    role="user",
                    content=TextContent(
                        type="text",
                        text=INGEST_KNOWLEDGE_PROMPT
                    )
                )
            ]
        )
    elif name == "crag_orchestrator":
        return GetPromptResult(
            description="",
            messages=[
                PromptMessage(
                    role="user",
                    content=TextContent(
                        type="text",
                        text=CRAG_ORCHESTRATOR_PROMPT
                    )
                )
            ]
        )
    raise ValueError(f"Prompt not found: {name}")


from backend.mcp_server.handlers.tool_registry import REGISTERED_TOOLS, TOOL_HANDLERS


async def handle_list_tools(ctx, params) -> ListToolsResult:
    """List available tools."""
    return ListToolsResult(tools=REGISTERED_TOOLS)

async def handle_call_tool(ctx, params) -> CallToolResult:
    """Handle tool execution requests dynamically via TOOL_HANDLERS registry."""
    name = params.name
    args = params.arguments or {}
    tenant_id = tenant_context.get()

    handler = TOOL_HANDLERS.get(name)
    if not handler:
        return CallToolResult(content=[TextContent(type="text", text=f"Error executing tool {name}: Unknown tool")])

    try:
        return CallToolResult(content=handler(args, tenant_id))
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        return CallToolResult(content=[TextContent(type="text", text=f"Error executing tool {name}: {e!s}")])

mcp_server = Server(
    "veraxi_mcp",
    on_list_resources=handle_list_resources,
    on_read_resource=handle_read_resource,
    on_list_prompts=handle_list_prompts,
    on_get_prompt=handle_get_prompt,
    on_list_tools=handle_list_tools,
    on_call_tool=handle_call_tool
)
