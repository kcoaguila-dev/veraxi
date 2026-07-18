import logging
from typing import Tuple, List, Any
import json
from openai import OpenAI
import json
from backend.config import get_config
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.retrieval.merge_rank import merge_rank

logger = logging.getLogger(__name__)

def get_tools() -> list:
    config = get_config()
    return [
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
                            "description": "The text to search for."
                        },
                        "limit": {
                            "type": "integer",
                            "description": f"Maximum number of results to return (default {config.default_search_limit})."
                        }
                    },
                    "required": ["query_text"]
                }
            }
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
                            "description": "The name of the entity to start the traversal from."
                        },
                        "max_hops": {
                            "type": "integer",
                            "description": f"Maximum number of relationship hops (default {config.default_max_hops})."
                        }
                    },
                    "required": ["entity_name"]
                }
            }
        }
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
        tool_name = function_call.function.name
        tool_input = json.loads(function_call.function.arguments)

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
    client_args = {}
    if config.llm_api_key:
        client_args["api_key"] = config.llm_api_key
    if config.llm_base_url:
        client_args["base_url"] = config.llm_base_url
        
    client = OpenAI(**client_args)

    # Step 1: Ask the LLM to decide on tools
    tools = get_tools()
    response = client.chat.completions.create(
        model=config.llm_model_name,
        messages=[{"role": "user", "content": question}],
        tools=tools,
        temperature=0.0
    )

    message = response.choices[0].message
    if not message.tool_calls:
        # LLM decided not to use tools
        logging.info("LLM did not call any tools. Returning its direct response.")
        return _format_return(message.content, "", return_context)

    # Step 2: Execute tools and merge results
    merged_results = _execute_and_merge_tools(message.tool_calls, tenant_id)
    if not merged_results:
        return _format_return(message.content or "No results found.", "", return_context)

    context_str = _build_context_string(merged_results)

    # Step 3: Ask LLM for final answer grounded in context
    final_prompt = (
        f"Please answer the following question strictly based on the provided context.\n\n"
        f"Context:\n{context_str}\n\n"
        f"Question: {question}"
    )

    final_response = client.chat.completions.create(
        model=config.llm_model_name,
        messages=[{"role": "user", "content": final_prompt}],
        temperature=0.0
    )

    return _format_return(final_response.choices[0].message.content, context_str, return_context)
