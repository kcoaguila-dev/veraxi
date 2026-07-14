import logging
from google import genai
from google.genai import types
from backend.config import get_config
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.retrieval.merge_rank import merge_rank

logger = logging.getLogger(__name__)

TOOLS = [
    types.Tool(
        function_declarations=[
            types.FunctionDeclaration(
                name="search_vectors",
                description="Search for semantically similar text chunks in the vector database.",
                parameters=types.Schema(
                    type=types.Type.OBJECT,
                    properties={
                        "query_text": types.Schema(type=types.Type.STRING, description="The text to search for."),
                        "limit": types.Schema(type=types.Type.INTEGER, description="Maximum number of results to return (default 10).")
                    },
                    required=["query_text"]
                )
            ),
            types.FunctionDeclaration(
                name="query_graph",
                description="Query the knowledge graph starting from a specific entity.",
                parameters=types.Schema(
                    type=types.Type.OBJECT,
                    properties={
                        "entity_name": types.Schema(type=types.Type.STRING, description="The name of the entity to start the traversal from."),
                        "max_hops": types.Schema(type=types.Type.INTEGER, description="Maximum number of relationship hops (default 2).")
                    },
                    required=["entity_name"]
                )
            )
        ]
    )
]


def answer_question(question: str, tenant_id: str = "default") -> str:
    """
    LLM decides whether to call search_vectors and/or query_graph, gets results back,
    calls merge_rank to fuse them, then produces a final answer grounded in the fused results.
    Logs the provenance.
    """
    config = get_config()
    client = genai.Client(api_key=config.gemini_api_key)

    # Step 1: Ask the LLM to decide on tools
    response = client.models.generate_content(
        model="gemini-2.5-flash",
        contents=[question],
        config=types.GenerateContentConfig(
            tools=TOOLS,
            temperature=0.0
        )
    )

    vector_hits = []
    graph_hits = []

    if response.function_calls:
        for function_call in response.function_calls:
            tool_name = function_call.name
            tool_input = function_call.args

            logging.info(f"LLM called tool: {tool_name} with args: {tool_input}")

            if tool_name == "search_vectors":
                limit = int(tool_input.get("limit", 10))
                vector_hits.extend(search_vectors(tool_input["query_text"], limit=limit, tenant_id=tenant_id))
            elif tool_name == "query_graph":
                max_hops = int(tool_input.get("max_hops", 2))
                graph_hits.extend(query_graph(tool_input["entity_name"], max_hops=max_hops, tenant_id=tenant_id))

    # Step 2: Merge and rank the results if any tools were called
    if vector_hits or graph_hits:
        merged_results = merge_rank(vector_hits, graph_hits)

        logging.info(f"Provenance: Generated {len(merged_results)} fused results from tools.")

        # Build context string
        context_parts = []
        for i, res in enumerate(merged_results, 1):
            source_info = " and ".join(res.sources)
            payload_str = str(res.payload)
            context_parts.append(f"[Result {i} (from {source_info})]: {payload_str}")

        context_str = "\n".join(context_parts)

        # Step 3: Ask LLM for final answer grounded in context
        final_prompt = (
            f"Please answer the following question strictly based on the provided context.\n\n"
            f"Context:\n{context_str}\n\n"
            f"Question: {question}"
        )

        final_response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=[final_prompt],
            config=types.GenerateContentConfig(temperature=0.0)
        )

        return final_response.text
    else:
        # LLM decided not to use tools
        logging.info("LLM did not call any tools. Returning its direct response.")
        return response.text
