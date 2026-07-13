import logging
from mcp.server import Server
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph

logger = logging.getLogger(__name__)

# Initialize the MCP Server
mcp_server = Server("veraxi_mcp")

@mcp_server.tool()
def mcp_search_vectors(query_text: str, limit: int = 10) -> str:
    """
    Search for semantically similar text chunks in the vector database.
    Returns the textual payload of the most similar chunks.
    """
    try:
        hits = search_vectors(query_text, limit=limit)
        results = [hit.payload.get("text", "") for hit in hits]
        return "\n\n".join(results)
    except Exception as e:
        logger.error(f"Error in search_vectors tool: {e}")
        return f"Error executing tool: {e}"

@mcp_server.tool()
def mcp_query_graph(entity_name: str, max_hops: int = 2) -> str:
    """
    Query the knowledge graph starting from a specific entity out to max_hops.
    Returns connected entities and their properties.
    """
    try:
        hits = query_graph(entity_name, max_hops=max_hops)
        # Format the hits into a readable string
        results = []
        for hit in hits:
            labels = ", ".join(hit.payload.get("labels", []))
            name = hit.payload.get("name", "Unknown")
            # Other properties
            props = {k: v for k, v in hit.payload.items() if k not in ["labels", "name"]}
            results.append(f"Entity: {name} (Types: {labels}) - Properties: {props}")
        return "\n".join(results)
    except Exception as e:
        logger.error(f"Error in query_graph tool: {e}")
        return f"Error executing tool: {e}"
