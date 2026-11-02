import json

from mcp.server.mcpserver import MCPServer

from backend.config import get_config
from backend.mcp_server.context import tenant_context
from backend.mcp_server.handlers.tool_registry import TOOL_HANDLERS
from backend.mcp_server.tools.get_schema import get_graph_schema
from backend.mcp_server.tools.get_stats import get_database_stats
from backend.prompts import CRAG_ORCHESTRATOR_PROMPT, INGEST_KNOWLEDGE_PROMPT

mcp_server = MCPServer("veraxi_mcp")


def _dispatch(tool_name: str, args: dict) -> str:
    tenant_id = tenant_context.get()
    res = TOOL_HANDLERS[tool_name](args, tenant_id)
    return res[0].text if res else "[]"


async def _adispatch(tool_name: str, args: dict) -> str:
    tenant_id = tenant_context.get()
    res = await TOOL_HANDLERS[tool_name](args, tenant_id)
    return res[0].text if res else "[]"


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
    name="mcp_search_vectors",
    description="[FAST - Vector Only (<50ms)] Semantic vector search over document chunks. Use when searching purely by text similarity without graph relationship traversal.",
)
def mcp_search_vectors(query_text: str, limit: int = 10) -> str:
    return _dispatch("mcp_search_vectors", {"query_text": query_text, "limit": limit})


@mcp_server.tool(
    name="mcp_query_graph",
    description="[FAST - Graph Only (<50ms)] Multi-hop relationship traversal from a known entity in Neo4j. Use when exploring entity connections, dependencies, or causal chains.",
)
def mcp_query_graph(entity_name: str, max_hops: int = 2) -> str:
    return _dispatch(
        "mcp_query_graph", {"entity_name": entity_name, "max_hops": max_hops}
    )


@mcp_server.tool(
    name="mcp_insert_graph_nodes",
    description="Insert structured nodes and relations into the Neo4j Knowledge Graph. The Host AI should extract these from unstructured text first.",
)
def mcp_insert_graph_nodes(nodes: list, relations: list) -> str:
    return _dispatch("mcp_insert_graph_nodes", {"nodes": nodes, "relations": relations})


@mcp_server.tool(
    name="mcp_insert_vectors",
    description="Generate embeddings and insert text chunks into the Qdrant Vector Database.",
)
def mcp_insert_vectors(texts: list) -> str:
    return _dispatch("mcp_insert_vectors", {"texts": texts})


@mcp_server.tool(
    name="mcp_merge_rank",
    description="[DEFAULT - Fast (<100ms)] Primary hybrid GraphRAG search tool. Use for 95% of queries, codebase navigation, fact lookup, and general Q&A. Searches vector embeddings and traverses entity relationships in Neo4j.",
)
def mcp_merge_rank(
    query_text: str, entity_name: str = "", limit: int = 10, max_hops: int = 2
) -> str:
    return _dispatch(
        "mcp_merge_rank",
        {
            "query_text": query_text,
            "entity_name": entity_name,
            "limit": limit,
            "max_hops": max_hops,
        },
    )


@mcp_server.tool(
    name="mcp_get_graph_schema",
    description="Retrieves all unique Node Labels and Relationship Types currently in the Neo4j database. Call this before inserting data to understand the current schema.",
)
def mcp_get_graph_schema() -> str:
    return _dispatch("mcp_get_graph_schema", {})


@mcp_server.tool(
    name="mcp_delete_entity",
    description="Deletes a specific entity and all its relationships from Neo4j.",
)
def mcp_delete_entity(entity_name: str) -> str:
    return _dispatch("mcp_delete_entity", {"entity_name": entity_name})


@mcp_server.tool(
    name="mcp_delete_document",
    description="Deletes a specific document chunk from Qdrant using its document ID.",
)
def mcp_delete_document(document_id: str) -> str:
    return _dispatch("mcp_delete_document", {"document_id": document_id})


@mcp_server.tool(
    name="mcp_update_entity",
    description="Updates the properties of an existing Neo4j entity. Only provide the properties you want to add or overwrite.",
)
def mcp_update_entity(entity_name: str, properties: dict) -> str:
    return _dispatch(
        "mcp_update_entity", {"entity_name": entity_name, "properties": properties}
    )


@mcp_server.tool(
    name="mcp_get_database_stats",
    description="Retrieves high-level statistics about the size of the database (nodes, relationships, vectors).",
)
def mcp_get_database_stats() -> str:
    return _dispatch("mcp_get_database_stats", {})


@mcp_server.tool(
    name="mcp_run_community_detection",
    description="Runs a Graph Data Science community detection algorithm to find clusters of connected entities.",
)
def mcp_run_community_detection(min_size: int = 2) -> str:
    return _dispatch("mcp_run_community_detection", {"min_size": min_size})


@mcp_server.tool(
    name="mcp_delete_relationship",
    description="Deletes a specific relationship edge between two entities without deleting the entities themselves.",
)
def mcp_delete_relationship(from_entity: str, to_entity: str, rel_type: str) -> str:
    return _dispatch(
        "mcp_delete_relationship",
        {"from_entity": from_entity, "to_entity": to_entity, "rel_type": rel_type},
    )


@mcp_server.tool(
    name="mcp_update_document_metadata",
    description="Updates or adds metadata properties to an existing vector document chunk in Qdrant.",
)
def mcp_update_document_metadata(document_id: str, payload: dict) -> str:
    return _dispatch(
        "mcp_update_document_metadata",
        {"document_id": document_id, "payload": payload},
    )


@mcp_server.tool(
    name="mcp_evaluate_grounding",
    description="Evaluates what percentage of a generated response is mathematically supported by the retrieved context. Supports 'deterministic' ($0 cost, fast, local) and 'llm' (deep semantic entailment via user BYOK key) modes. Returns a float between 0.0 and 1.0.",
)
def mcp_evaluate_grounding(
    response_text: str,
    context_text: str,
    method: str = "auto",
    api_key: str | None = None,
    model_name: str | None = None,
) -> str:
    return _dispatch(
        "mcp_evaluate_grounding",
        {
            "response_text": response_text,
            "context_text": context_text,
            "method": method,
            "api_key": api_key,
            "model_name": model_name,
        },
    )


@mcp_server.tool(
    name="mcp_fact_check",
    description="[FACT-CHECK PROOF ENGINE] Verify any financial claim against the knowledge base. Extracts verbatim sub-sentence quote, exact page number, and clickable PDF link (OSC 8 / Markdown), returning a formatted proof card with page peek.",
)
def mcp_fact_check(claim: str, min_score: float = 0.8, peek: bool = True) -> str:
    return _dispatch(
        "mcp_fact_check",
        {"claim": claim, "min_score": min_score, "peek": peek},
    )


@mcp_server.tool(
    name="mcp_web_search",
    description="Fallback mechanism to search the live web when internal retrieval yields insufficient context. Returns a list of JSON snippets.",
)
def mcp_web_search(query: str | None = None, max_results: int = 3) -> str:
    return _dispatch("mcp_web_search", {"query": query, "max_results": max_results})


@mcp_server.tool(
    name="mcp_skills",
    description="Lists available agentic skills for tool augmentation.",
)
def mcp_skills() -> str:
    return _dispatch("mcp_skills", {})


@mcp_server.tool(
    name="mcp_run_code",
    description="Executes Python code in a local subprocess with timeout and sanitised environment (no secret access). Returns stdout/stderr.",
)
def mcp_run_code(code: str) -> str:
    return _dispatch("mcp_run_code", {"code": code})


@mcp_server.tool(
    name="mcp_list_artifacts",
    description="Lists all artifacts stored in the workspace for the current tenant.",
)
def mcp_list_artifacts() -> str:
    return _dispatch("mcp_list_artifacts", {})


@mcp_server.tool(
    name="mcp_read_artifact",
    description="Reads the content of a specific artifact by its name.",
)
def mcp_read_artifact(artifact_name: str) -> str:
    return _dispatch("mcp_read_artifact", {"artifact_name": artifact_name})


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
    return _dispatch(
        "mcp_ingest_document",
        {
            "file_path": file_path,
            "url": url,
            "fast_extraction": fast_extraction,
            "language": language,
            "chunk_size": chunk_size,
            "chunk_overlap": chunk_overlap,
            "wait_for_completion": wait_for_completion,
        },
    )


@mcp_server.tool(
    name="mcp_get_ingest_status",
    description="Polls the status of an active ingestion job.",
)
def mcp_get_ingest_status(job_id: str) -> str:
    return _dispatch("mcp_get_ingest_status", {"job_id": job_id})


@mcp_server.tool(
    name="mcp_dynamic_web_graph",
    description="Dynamic Web Search GraphRAG - searches the web and returns a structured Knowledge Graph of entities and relations instead of raw text snippets, allowing for high-accuracy multi-hop reasoning over live data.",
)
def mcp_dynamic_web_graph(
    query: str, language: str = "en", max_results: int = 5
) -> str:
    return _dispatch(
        "mcp_dynamic_web_graph",
        {"query": query, "language": language, "max_results": max_results},
    )


@mcp_server.tool(
    name="mcp_ephemeral_web_rag",
    description="[DEEP WEB CRAWL & RAG - Moderate (3-8s)] Full-page web crawler and temporary GraphRAG indexer. DO NOT use for simple fact lookups or finding links (use native host web search for that). Use this when you need to read FULL contents of external documentation, articles, or URLs (pass in 'urls' array), extract their entities into a temporary sandboxed graph, and perform structured RAG over the crawled text.",
)
def mcp_ephemeral_web_rag(
    query: str | None = None, max_results: int = 3, urls: list | None = None
) -> str:
    return _dispatch(
        "mcp_ephemeral_web_rag",
        {"query": query, "max_results": max_results, "urls": urls},
    )


@mcp_server.tool(
    name="mcp_agentic_debate",
    description="[HEAVY - Long Running (15-30s)] Multi-agent debate swarm with adversarial Skeptic fact-checking. Dispatches Vector, Knowledge Graph, and Web specialists, synthesizes evidence with strict citations, and enforces an adversarial verification loop. ONLY call when the user explicitly asks for 'deep research', 'exhaustive audit', or 'multi-agent debate'. Do not use for routine lookups.",
)
async def mcp_agentic_debate(query: str) -> str:
    return await _adispatch("mcp_agentic_debate", {"query": query})


@mcp_server.tool(
    name="mcp_export_data",
    description="Serializes and exports dynamically structured datasets into agnostic, interoperable file formats (CSV, OTIO, FCPXML). Facilitates seamless data handoff to external analytical pipelines, data science environments, and professional non-linear editing (NLE) systems without imposing domain-specific schemas.",
)
def mcp_export_data(
    data: list, format: str = "csv", output_name: str = "veraxi_export"
) -> str:
    return _dispatch(
        "mcp_export_data",
        {"data": data, "format": format, "output_name": output_name},
    )


@mcp_server.tool(
    name="mcp_build_lazy_dossier",
    description="Extracts a comprehensive research dossier from ingested documents using Hybrid Vector Search (Dense + SPLADE) fused with existing Neo4j entity anchors. Generates structured evidence chunks and instructions for Host AI to extract high-precision causal triples.",
)
def mcp_build_lazy_dossier(query: str, limit: int = 15) -> str:
    return _dispatch("mcp_build_lazy_dossier", {"query": query, "limit": limit})


@mcp_server.tool(
    name="mcp_purge_noisy_relationships",
    description="Purges all raw sentence-level co-occurrence ('MENTIONED_WITH') relationships from Neo4j for the current tenant. Leaves all entity nodes, book titles, and Qdrant vector links intact to eliminate graph noise.",
)
def mcp_purge_noisy_relationships() -> str:
    return _dispatch("mcp_purge_noisy_relationships", {})


AGENT_TOOLS: frozenset[str] = frozenset(
    [
        "mcp_merge_rank",
        "mcp_search_vectors",
        "mcp_query_graph",
        "mcp_evaluate_grounding",
        "mcp_ephemeral_web_rag",
        "mcp_agentic_debate",
        "mcp_ingest_document",
        "mcp_get_ingest_status",
        "mcp_get_database_stats",
        "mcp_fact_check",
    ]
)

AGENT_PROMPTS: frozenset[str] = frozenset(
    [
        "crag_orchestrator",
    ]
)


def apply_mcp_profile(server: MCPServer, profile: str) -> None:
    if profile == "agent":
        # Remove tools not in AGENT_TOOLS
        tools = [tool.name for tool in server._tool_manager.list_tools()]
        for tool_name in tools:
            if tool_name not in AGENT_TOOLS:
                server.remove_tool(tool_name)

        # Remove prompts not in AGENT_PROMPTS
        prompts = [prompt.name for prompt in server._prompt_manager.list_prompts()]
        for prompt_name in prompts:
            if prompt_name not in AGENT_PROMPTS:
                server.remove_prompt(prompt_name)


apply_mcp_profile(mcp_server, get_config().mcp_tool_profile)
