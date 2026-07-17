import logging
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.retrieval.merge_rank import merge_rank

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")


def test_integration():
    """
    Non-destructive integration script to verify merge_rank against existing data.
    Assumes Phase 1 ingestion has already populated the database.
    """
    logging.info("Testing search_vectors...")
    vector_hits = search_vectors("Engineer", limit=5)
    logging.info(f"Found {len(vector_hits)} vector hits.")

    logging.info("Testing query_graph...")
    graph_hits = query_graph("Alice", max_hops=1)
    logging.info(f"Found {len(graph_hits)} graph hits.")

    logging.info("Testing merge_rank...")
    merged = merge_rank(vector_hits, graph_hits)
    logging.info(f"Generated {len(merged)} merged results.")

    if merged:
        top_result = merged[0]
        logging.info(f"Top result score: {top_result.fused_score}")
        logging.info(f"Top result sources: {top_result.sources}")


if __name__ == "__main__":
    test_integration()
