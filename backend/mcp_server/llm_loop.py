import logging
from typing import Tuple, List, Any
from google import genai
from google.genai import types
from backend.config import get_config
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.retrieval.merge_rank import merge_rank

logger = logging.getLogger(__name__)

def get_tools() -> list:
    config = get_config()
    return [
        types.Tool(
            function_declarations=[
                types.FunctionDeclaration(
                    name="search_vectors",
                    description="Search for semantically similar text chunks in the vector database.",
                    parameters=types.Schema(
                        type=types.Type.OBJECT,
                        properties={
                            "query_text": types.Schema(
                                type=types.Type.STRING,
                                description="The text to search for.",
                            ),
                            "limit": types.Schema(
                                type=types.Type.INTEGER,
                                description=f"Maximum number of results to return (default {config.default_search_limit}).",
                            ),
                        },
                        required=["query_text"],
                    ),
                ),
                types.FunctionDeclaration(
                    name="query_graph",
                    description="Query the knowledge graph starting from a specific entity.",
                    parameters=types.Schema(
                        type=types.Type.OBJECT,
                        properties={
                            "entity_name": types.Schema(
                                type=types.Type.STRING,
                                description="The name of the entity to start the traversal from.",
                            ),
                            "max_hops": types.Schema(
                                type=types.Type.INTEGER,
                                description=f"Maximum number of relationship hops (default {config.default_max_hops}).",
                            ),
                        },
                        required=["entity_name"],
                    ),
                ),
            ]
        )
    ]


def _execute_single_tool(tool_name: str, tool_input: dict, tenant_id: str) -> Tuple[List[Any], List[Any]]:
    config = get_config()
    if tool_name == "search_vectors":
        limit = int(tool_input.get("limit", config.default_search_limit))
        return search_vectors(tool_input["query_text"], limit=limit, tenant_id=tenant_id), []
    elif tool_name == "query_graph":
        max_hops = int(tool_input.get("max_hops", config.default_max_hops))
        return [], query_graph(tool_input["entity_name"], max_hops=max_hops, tenant_id=tenant_id)
    return [], []

def _execute_tools(
    function_calls: List[Any], tenant_id: str
) -> Tuple[List[Any], List[Any]]:
    """Execute LLM requested tools and return vectors and graph hits."""
    vector_hits = []
    graph_hits = []

    for function_call in function_calls:
        tool_name = function_call.name
        tool_input = function_call.args

        logging.info(f"LLM called tool: {tool_name} with args: {tool_input}")
        
        v_hits, g_hits = _execute_single_tool(tool_name, tool_input, tenant_id)
        vector_hits.extend(v_hits)
        graph_hits.extend(g_hits)

    return vector_hits, graph_hits


def _build_context_string(merged_results: List[Any]) -> str:
    """Build a formatted context string from fused results."""
    context_parts = []
    for i, res in enumerate(merged_results, 1):
        source_info = " and ".join(res.sources)
        payload_str = str(res.payload)
        context_parts.append(f"[Result {i} (from {source_info})]: {payload_str}")

    return "\n".join(context_parts)


def _execute_and_merge_tools(function_calls, tenant_id: str) -> list:
    vector_hits, graph_hits = _execute_tools(function_calls, tenant_id)
    if not vector_hits and not graph_hits:
        return []
    
    merged = merge_rank(vector_hits, graph_hits)
    logging.info(f"Provenance: Generated {len(merged)} fused results from tools.")
    return merged

def _format_return(text: str, context: str, return_context: bool) -> str | Tuple[str, str]:
    if return_context:
        return text, context
    return text

def answer_question(question: str, tenant_id: str = "default", return_context: bool = False) -> str | Tuple[str, str]:
    """
    LLM decides whether to call search_vectors and/or query_graph, gets results back,
    calls merge_rank to fuse them, then produces a final answer grounded in the fused results.
    Logs the provenance.
    If return_context is True, returns (final_answer, context_str).
    """
    config = get_config()
    client = genai.Client(api_key=config.llm_api_key)

    # Step 1: Ask the LLM to decide on tools
    tools = get_tools()
    response = client.models.generate_content(
        model=config.llm_model_name,
        contents=[question],
        config=types.GenerateContentConfig(tools=tools, temperature=0.0),
    )

    if not response.function_calls:
        # LLM decided not to use tools
        logging.info("LLM did not call any tools. Returning its direct response.")
        return _format_return(response.text, "", return_context)

    # Step 2: Execute tools and merge results
    merged_results = _execute_and_merge_tools(response.function_calls, tenant_id)
    if not merged_results:
        return _format_return(response.text, "", return_context)

    context_str = _build_context_string(merged_results)

    # Step 3: Ask LLM for final answer grounded in context
    final_prompt = (
        f"Please answer the following question strictly based on the provided context.\n\n"
        f"Context:\n{context_str}\n\n"
        f"Question: {question}"
    )

    final_response = client.models.generate_content(
        model=config.llm_model_name,
        contents=[final_prompt],
        config=types.GenerateContentConfig(temperature=0.0),
    )

    return _format_return(final_response.text, context_str, return_context)
