import json

from backend.mcp_server.context import tenant_context
from backend.mcp_server.tools.get_schema import get_graph_schema
from backend.mcp_server.tools.get_stats import get_database_stats
from backend.prompts import CRAG_ORCHESTRATOR_PROMPT, INGEST_KNOWLEDGE_PROMPT
from mcp.server.mcpserver import MCPServer

mcp_server = MCPServer("veraxi_mcp")


@mcp_server.resource("veraxi://schema")
def handle_read_schema() -> str:
    """The current schema of node labels and relationship types in the Neo4j Graph."""
    results = get_graph_schema()
    return json.dumps(results)


@mcp_server.resource("veraxi://stats")
def handle_read_stats() -> str:
    """Live counts of nodes, vectors, and relationships for the current tenant."""
    tenant_id = tenant_context.get()
    return json.dumps(get_database_stats(tenant_id=tenant_id))


@mcp_server.prompt("ingest_knowledge")
def prompt_ingest_knowledge() -> str:
    """Provides strict instructions to the Host AI on how to read source material and construct GraphRAG structures."""
    return INGEST_KNOWLEDGE_PROMPT


@mcp_server.prompt("crag_orchestrator")
def prompt_crag_orchestrator() -> str:
    """Instructs the Host AI to act as a Corrective Retrieval Augmented Generation orchestrator, combining internal database retrieval with live web search."""
    return CRAG_ORCHESTRATOR_PROMPT


@mcp_server.tool(
    name="mcp_search_vectors", description="Semantic search over documents"
)
def mcp_search_vectors(query_text: str, limit: int = 10) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_search_vectors

    res = _handle_search_vectors(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(name="mcp_query_graph", description="Find exact entity relationships")
def mcp_query_graph(entity_name: str, max_hops: int = 2) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_query_graph

    res = _handle_query_graph(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_insert_graph_nodes",
    description="Insert structured nodes and relations into the Neo4j Knowledge Graph. The Host AI should extract these from unstructured text first.",
)
def mcp_insert_graph_nodes(nodes: list, relations: list) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_insert_graph_nodes

    res = _handle_insert_graph_nodes(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_insert_vectors",
    description="Generate embeddings and insert text chunks into the Qdrant Vector Database.",
)
def mcp_insert_vectors(texts: list) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_insert_vectors

    res = _handle_insert_vectors(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_merge_rank",
    description="Perform a unified GraphRAG search. It searches vectors using query_text and traverses the graph from entity_name, then fuses the results using Reciprocal Rank Fusion.",
)
def mcp_merge_rank(
    query_text: str, entity_name: str, limit: int = 10, max_hops: int = 2
) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_merge_rank

    res = _handle_merge_rank(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_get_graph_schema",
    description="Retrieves all unique Node Labels and Relationship Types currently in the Neo4j database. Call this before inserting data to understand the current schema.",
)
def mcp_get_graph_schema() -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_get_graph_schema

    res = _handle_get_graph_schema(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_delete_entity",
    description="Deletes a specific entity and all its relationships from Neo4j.",
)
def mcp_delete_entity(entity_name: str) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_delete_entity

    res = _handle_delete_entity(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_delete_document",
    description="Deletes a specific document chunk from Qdrant using its document ID.",
)
def mcp_delete_document(document_id: str) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_delete_document

    res = _handle_delete_document(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_update_entity",
    description="Updates the properties of an existing Neo4j entity. Only provide the properties you want to add or overwrite.",
)
def mcp_update_entity(entity_name: str, properties: dict) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_update_entity

    res = _handle_update_entity(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_get_database_stats",
    description="Retrieves high-level statistics about the size of the database (nodes, relationships, vectors).",
)
def mcp_get_database_stats() -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_get_database_stats

    res = _handle_get_database_stats(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_run_community_detection",
    description="Runs a Graph Data Science community detection algorithm to find clusters of connected entities.",
)
def mcp_run_community_detection(min_size: int = 2) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import (
        _handle_run_community_detection,
    )

    res = _handle_run_community_detection(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_delete_relationship",
    description="Deletes a specific relationship edge between two entities without deleting the entities themselves.",
)
def mcp_delete_relationship(from_entity: str, to_entity: str, rel_type: str) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_delete_relationship

    res = _handle_delete_relationship(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_update_document_metadata",
    description="Updates or adds metadata properties to an existing vector document chunk in Qdrant.",
)
def mcp_update_document_metadata(document_id: str, payload: dict) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import (
        _handle_update_document_metadata,
    )

    res = _handle_update_document_metadata(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_evaluate_grounding",
    description="Evaluates what percentage of a generated response is mathematically supported by the retrieved context. Returns a float between 0.0 and 1.0.",
)
def mcp_evaluate_grounding(response_text: str, context_text: str) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_evaluate_grounding

    res = _handle_evaluate_grounding(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_web_search",
    description="Fallback mechanism to search the live web when internal retrieval yields insufficient context. Returns a list of JSON snippets.",
)
def mcp_web_search(query: str | None = None, max_results: int = 3) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_web_search

    res = _handle_web_search(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_skills",
    description="Lists available agentic skills for tool augmentation.",
)
def mcp_skills() -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_skills

    res = _handle_skills(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_run_code",
    description="Executes Python code in a secure sandbox and returns the stdout/stderr.",
)
def mcp_run_code(code: str) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_run_code

    res = _handle_run_code(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_list_artifacts",
    description="Lists all artifacts stored in the workspace for the current tenant.",
)
def mcp_list_artifacts() -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_list_artifacts

    res = _handle_list_artifacts(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_read_artifact",
    description="Reads the content of a specific artifact by its name.",
)
def mcp_read_artifact(artifact_name: str) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_read_artifact

    res = _handle_read_artifact(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_ingest_document",
    description="Submits a document or URL to Veraxi's native ingestion pipeline (OCR -> Graph extraction -> Insertion).",
)
def mcp_ingest_document(
    file_path: str | None = None,
    url: str | None = None,
    fast_extraction: bool = False,
    language: str = "en",
    chunk_size: int = 200,
    chunk_overlap: int = 50,
    wait_for_completion: bool = False,
) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_ingest_document

    res = _handle_ingest_document(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_get_ingest_status",
    description="Polls the status of an active ingestion job.",
)
def mcp_get_ingest_status(job_id: str) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_get_ingest_status

    res = _handle_get_ingest_status(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_dynamic_web_graph",
    description="Dynamic Web Search GraphRAG - searches the web and returns a structured Knowledge Graph of entities and relations instead of raw text snippets, allowing for high-accuracy multi-hop reasoning over live data.",
)
def mcp_dynamic_web_graph(
    query: str, language: str = "en", max_results: int = 5
) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_dynamic_web_graph

    res = _handle_dynamic_web_graph(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_deep_research",
    description="Performs deep web research. Searches the internet, dynamically ingests the top results into your Hybrid RAG database, and returns mathematically ranked facts. Use this for complex research where standard web search lacks depth or relational accuracy. If you already have URLs to research, provide them in the 'urls' array.",
)
def mcp_deep_research(
    query: str | None = None, max_results: int = 3, urls: list | None = None
) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_deep_research

    res = _handle_deep_research(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text


@mcp_server.tool(
    name="mcp_export_data",
    description="Serializes and exports dynamically structured datasets into agnostic, interoperable file formats (CSV, OTIO, FCPXML). Facilitates seamless data handoff to external analytical pipelines, data science environments, and professional non-linear editing (NLE) systems without imposing domain-specific schemas.",
)
def mcp_export_data(
    data: list, format: str = "csv", output_name: str = "veraxi_export"
) -> str:
    tenant_id = tenant_context.get()
    args = {k: v for k, v in locals().items() if k != "tenant_id"}
    from backend.mcp_server.handlers.tool_registry import _handle_export_data

    res = _handle_export_data(args, tenant_id)
    # The old handler returns list[TextContent]. MCPServer expects str.
    return res[0].text
