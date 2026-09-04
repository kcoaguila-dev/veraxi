import dataclasses
import json

import sentry_sdk
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
    Tool,
)

from backend.config import get_config
from backend.mcp_server.context import tenant_context
from backend.mcp_server.tools.delete_entity import delete_entity
from backend.mcp_server.tools.delete_relationship import delete_relationship
from backend.mcp_server.tools.delete_vector import delete_vector
from backend.mcp_server.tools.get_schema import get_graph_schema
from backend.mcp_server.tools.get_stats import get_database_stats
from backend.mcp_server.tools.insert_graph import insert_graph_nodes
from backend.mcp_server.tools.insert_vector import insert_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.mcp_server.tools.run_analytics import run_community_detection
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.update_document import update_document_metadata
from backend.mcp_server.tools.update_entity import update_entity
from backend.mcp_server.tools.ingest_document import mcp_ingest_document, mcp_get_ingest_status
from backend.prompts import CRAG_ORCHESTRATOR_PROMPT, INGEST_KNOWLEDGE_PROMPT
from backend.storage.quota import check_tenant_hard_cap


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


REGISTERED_TOOLS = [
    Tool(
        name="mcp_search_vectors",
        description="Semantic search over documents",
        inputSchema={
            "type": "object",
            "properties": {
                "query_text": {"type": "string"},
                "limit": {"type": "integer", "default": 10},
            },
            "required": ["query_text"],
        },
    ),
    Tool(
        name="mcp_query_graph",
        description="Find exact entity relationships",
        inputSchema={
            "type": "object",
            "properties": {
                "entity_name": {"type": "string"},
                "max_hops": {"type": "integer", "default": 2},
            },
            "required": ["entity_name"],
        },
    ),
    Tool(
        name="mcp_insert_graph_nodes",
        description="Insert structured nodes and relations into the Neo4j Knowledge Graph. The Host AI should extract these from unstructured text first.",
        inputSchema={
            "type": "object",
            "properties": {
                "nodes": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "type": {"type": "string"},
                            "name": {"type": "string"},
                            "properties": {"type": "object"}
                        },
                        "required": ["type", "name"]
                    }
                },
                "relations": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "from_entity": {"type": "string"},
                            "to_entity": {"type": "string"},
                            "type": {"type": "string"}
                        },
                        "required": ["from_entity", "to_entity", "type"]
                    }
                }
            },
            "required": ["nodes", "relations"],
        },
    ),
    Tool(
        name="mcp_insert_vectors",
        description="Generate embeddings and insert text chunks into the Qdrant Vector Database.",
        inputSchema={
            "type": "object",
            "properties": {
                "texts": {
                    "type": "array",
                    "items": {"type": "string"}
                }
            },
            "required": ["texts"],
        },
    ),
    Tool(
        name="mcp_merge_rank",
        description="Perform a unified GraphRAG search. It searches vectors using query_text and traverses the graph from entity_name, then fuses the results using Reciprocal Rank Fusion.",
        inputSchema={
            "type": "object",
            "properties": {
                "query_text": {"type": "string"},
                "entity_name": {"type": "string"},
                "limit": {"type": "integer", "default": 10},
                "max_hops": {"type": "integer", "default": 2},
            },
            "required": ["query_text", "entity_name"],
        },
    ),
    Tool(
        name="mcp_get_graph_schema",
        description="Retrieves all unique Node Labels and Relationship Types currently in the Neo4j database. Call this before inserting data to understand the current schema.",
        inputSchema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="mcp_delete_entity",
        description="Deletes a specific entity and all its relationships from Neo4j.",
        inputSchema={
            "type": "object",
            "properties": {
                "entity_name": {"type": "string"}
            },
            "required": ["entity_name"],
        },
    ),
    Tool(
        name="mcp_delete_document",
        description="Deletes a specific document chunk from Qdrant using its document ID.",
        inputSchema={
            "type": "object",
            "properties": {
                "document_id": {"type": "string"}
            },
            "required": ["document_id"],
        },
    ),
    Tool(
        name="mcp_update_entity",
        description="Updates the properties of an existing Neo4j entity. Only provide the properties you want to add or overwrite.",
        inputSchema={
            "type": "object",
            "properties": {
                "entity_name": {"type": "string"},
                "properties": {"type": "object"}
            },
            "required": ["entity_name", "properties"],
        },
    ),
    Tool(
        name="mcp_get_database_stats",
        description="Retrieves high-level statistics about the size of the database (nodes, relationships, vectors).",
        inputSchema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="mcp_run_community_detection",
        description="Runs a Graph Data Science community detection algorithm to find clusters of connected entities.",
        inputSchema={
            "type": "object",
            "properties": {
                "min_size": {"type": "integer", "default": 2}
            },
        },
    ),
    Tool(
        name="mcp_delete_relationship",
        description="Deletes a specific relationship edge between two entities without deleting the entities themselves.",
        inputSchema={
            "type": "object",
            "properties": {
                "from_entity": {"type": "string"},
                "to_entity": {"type": "string"},
                "rel_type": {"type": "string"}
            },
            "required": ["from_entity", "to_entity", "rel_type"],
        },
    ),
    Tool(
        name="mcp_update_document_metadata",
        description="Updates or adds metadata properties to an existing vector document chunk in Qdrant.",
        inputSchema={
            "type": "object",
            "properties": {
                "document_id": {"type": "string"},
                "payload": {"type": "object"}
            },
            "required": ["document_id", "payload"],
        },
    ),
    Tool(
        name="mcp_evaluate_grounding",
        description="Evaluates what percentage of a generated response is mathematically supported by the retrieved context. Returns a float between 0.0 and 1.0.",
        inputSchema={
            "type": "object",
            "properties": {
                "response_text": {"type": "string"},
                "context_text": {"type": "string"}
            },
            "required": ["response_text", "context_text"],
        },
    ),
    Tool(
        name="mcp_web_search",
        description="Fallback mechanism to search the live web when internal retrieval yields insufficient context. Returns a list of JSON snippets.",
        inputSchema={
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "max_results": {"type": "integer", "default": 3}
            },
        },
    ),
    Tool(
        name="mcp_skills",
        description="Lists available agentic skills for tool augmentation.",
        inputSchema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="mcp_run_code",
        description="Executes Python code in a secure sandbox and returns the stdout/stderr.",
        inputSchema={
            "type": "object",
            "properties": {
                "code": {"type": "string"},
            },
            "required": ["code"],
        },
    ),
    Tool(
        name="mcp_list_artifacts",
        description="Lists all artifacts stored in the workspace for the current tenant.",
        inputSchema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="mcp_read_artifact",
        description="Reads the content of a specific artifact by its name.",
        inputSchema={
            "type": "object",
            "properties": {
                "artifact_name": {"type": "string"},
            },
            "required": ["artifact_name"],
        },
    ),
    Tool(
        name="mcp_ingest_document",
        description="Submits a document or URL to Veraxi's native ingestion pipeline (OCR -> Graph extraction -> Insertion).",
        inputSchema={
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Absolute path to a local document file."},
                "url": {"type": "string", "description": "URL to scrape and ingest instead of a local file."},
                "fast_extraction": {"type": "boolean", "default": False},
                "language": {"type": "string", "default": "en"},
                "chunk_size": {"type": "integer", "default": 200},
                "chunk_overlap": {"type": "integer", "default": 50},
                "wait_for_completion": {"type": "boolean", "default": False, "description": "If true, the tool will block and poll internally until ingestion is complete."}
            },
        },
    ),
    Tool(
        name="mcp_get_ingest_status",
        description="Polls the status of an active ingestion job.",
        inputSchema={
            "type": "object",
            "properties": {
                "job_id": {"type": "string", "description": "The job ID returned from mcp_ingest_document."}
            },
            "required": ["job_id"],
        },
    ),
]

def _handle_search_vectors(args: dict, tenant_id: str) -> list[TextContent]:
    config = get_config()
    results = search_vectors(
        query_text=args["query_text"],
        limit=args.get("limit", config.default_search_limit),
        tenant_id=tenant_id
    )
    dict_results = [dataclasses.asdict(r) for r in results]
    return [TextContent(type="text", text=json.dumps(dict_results))]

def _handle_query_graph(args: dict, tenant_id: str) -> list[TextContent]:
    config = get_config()
    results = query_graph(
        entity_name=args["entity_name"],
        max_hops=args.get("max_hops", config.default_max_hops),
        tenant_id=tenant_id
    )
    return [TextContent(type="text", text=json.dumps(results))]

def _handle_insert_graph_nodes(args: dict, tenant_id: str) -> list[TextContent]:
    # Enforce the free-tier node cap on cloud deployments.
    # Self-hosted (auth_enabled=False) runs without limits — it's the user's own infra.
    config = get_config()
    if config.auth_enabled:
        check_tenant_hard_cap(tenant_id, config)
    results = insert_graph_nodes(
        nodes=args["nodes"],
        relations=args["relations"],
        tenant_id=tenant_id
    )
    return [TextContent(type="text", text=json.dumps(results))]

def _handle_insert_vectors(args: dict, tenant_id: str) -> list[TextContent]:
    # Same guard: cloud users are capped, self-hosted users are not.
    config = get_config()
    if config.auth_enabled:
        check_tenant_hard_cap(tenant_id, config)
    results = insert_vectors(
        texts=args["texts"],
        tenant_id=tenant_id
    )
    return [TextContent(type="text", text=json.dumps(results))]

def _handle_merge_rank(args: dict, tenant_id: str) -> list[TextContent]:
    import dataclasses

    from backend.retrieval.merge_rank import merge_rank
    
    config = get_config()
    
    v_hits = search_vectors(
        query_text=args["query_text"],
        limit=args.get("limit", config.default_search_limit),
        tenant_id=tenant_id
    )
    g_hits = query_graph(
        entity_name=args["entity_name"],
        max_hops=args.get("max_hops", config.default_max_hops),
        tenant_id=tenant_id
    )
    results = merge_rank(v_hits, g_hits, limit=args.get("limit", config.default_search_limit))
    dict_results = [dataclasses.asdict(r) for r in results]
    
    return [TextContent(type="text", text=json.dumps(dict_results))]

def _handle_get_graph_schema(args: dict, tenant_id: str) -> list[TextContent]:
    results = get_graph_schema()
    return [TextContent(type="text", text=json.dumps(results))]

def _handle_delete_entity(args: dict, tenant_id: str) -> list[TextContent]:
    result = delete_entity(args["entity_name"], tenant_id=tenant_id)
    return [TextContent(type="text", text=result)]

def _handle_delete_document(args: dict, tenant_id: str) -> list[TextContent]:
    result = delete_vector(args["document_id"], tenant_id=tenant_id)
    return [TextContent(type="text", text=result)]

def _handle_update_entity(args: dict, tenant_id: str) -> list[TextContent]:
    result = update_entity(args["entity_name"], args["properties"], tenant_id=tenant_id)
    return [TextContent(type="text", text=result)]

def _handle_get_database_stats(args: dict, tenant_id: str) -> list[TextContent]:
    results = get_database_stats(tenant_id=tenant_id)
    return [TextContent(type="text", text=json.dumps(results))]

def _handle_run_community_detection(args: dict, tenant_id: str) -> list[TextContent]:
    results = run_community_detection(args.get("min_size", 2))
    return [TextContent(type="text", text=json.dumps(results))]

def _handle_delete_relationship(args: dict, tenant_id: str) -> list[TextContent]:
    result = delete_relationship(args["from_entity"], args["to_entity"], args["rel_type"], tenant_id=tenant_id)
    return [TextContent(type="text", text=result)]

def _handle_update_document_metadata(args: dict, tenant_id: str) -> list[TextContent]:
    result = update_document_metadata(args["document_id"], args["payload"], tenant_id=tenant_id)
    return [TextContent(type="text", text=result)]

def _handle_evaluate_grounding(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.evaluate_grounding import mcp_evaluate_grounding
    score = mcp_evaluate_grounding(args["response_text"], args["context_text"])
    return [TextContent(type="text", text=str(score))]

def _handle_web_search(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.web_search import mcp_web_search
    tool_settings = args.get("_tool_settings", {})
    results = mcp_web_search(args["query"], args.get("max_results", 3), tool_settings=tool_settings)
    return [TextContent(type="text", text=json.dumps(results))]

def _handle_skills(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.skills import list_skills
    results = list_skills()
    return [TextContent(type="text", text=json.dumps(results))]

def _handle_run_code(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.run_code import execute_python_code
    result = execute_python_code(args["code"])
    return [TextContent(type="text", text=json.dumps(result))]

def _handle_list_artifacts(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.artifacts import list_artifacts
    results = list_artifacts(tenant_id)
    return [TextContent(type="text", text=json.dumps(results))]

def _handle_read_artifact(args: dict, tenant_id: str) -> list[TextContent]:
    from backend.mcp_server.tools.artifacts import read_artifact
    result = read_artifact(tenant_id, args["artifact_name"])
    return [TextContent(type="text", text=result)]

def _handle_ingest_document(args: dict, tenant_id: str) -> list[TextContent]:
    result = mcp_ingest_document(
        tenant_id=tenant_id,
        file_path=args.get("file_path"),
        url=args.get("url"),
        fast_extraction=args.get("fast_extraction", False),
        language=args.get("language", "en")
    )
    return [TextContent(type="text", text=json.dumps(result))]

def _handle_get_ingest_status(args: dict, tenant_id: str) -> list[TextContent]:
    result = mcp_get_ingest_status(tenant_id=tenant_id, job_id=args["job_id"])
    return [TextContent(type="text", text=json.dumps(result))]

TOOL_HANDLERS = {
    "mcp_search_vectors": _handle_search_vectors,
    "mcp_query_graph": _handle_query_graph,
    "mcp_insert_graph_nodes": _handle_insert_graph_nodes,
    "mcp_insert_vectors": _handle_insert_vectors,
    "mcp_merge_rank": _handle_merge_rank,
    "mcp_get_graph_schema": _handle_get_graph_schema,
    "mcp_delete_entity": _handle_delete_entity,
    "mcp_delete_document": _handle_delete_document,
    "mcp_update_entity": _handle_update_entity,
    "mcp_get_database_stats": _handle_get_database_stats,
    "mcp_run_community_detection": _handle_run_community_detection,
    "mcp_delete_relationship": _handle_delete_relationship,
    "mcp_update_document_metadata": _handle_update_document_metadata,
    "mcp_evaluate_grounding": _handle_evaluate_grounding,
    "mcp_web_search": _handle_web_search,
    "mcp_skills": _handle_skills,
    "mcp_run_code": _handle_run_code,
    "mcp_list_artifacts": _handle_list_artifacts,
    "mcp_read_artifact": _handle_read_artifact,
    "mcp_ingest_document": _handle_ingest_document,
    "mcp_get_ingest_status": _handle_get_ingest_status,
}

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
