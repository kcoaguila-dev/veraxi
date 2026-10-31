import argparse
import logging
import sys
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.retrieval.merge_rank import merge_rank

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s: %(message)s", datefmt="%H:%M:%S")

def test_integration(vector_query: str, graph_query: str):
    """
    Non-destructive integration script to verify merge_rank against existing data.
    """
    try:
        logging.info(f"Testing search_vectors with query: '{vector_query}'...")
        vector_hits = search_vectors(vector_query, limit=5)
        logging.info(f"Found {len(vector_hits)} vector hits.")

        logging.info(f"Testing query_graph with query: '{graph_query}'...")
        graph_hits = query_graph(graph_query, max_hops=1)
        logging.info(f"Found {len(graph_hits)} graph hits.")

        logging.info("Testing merge_rank...")
        merged = merge_rank(vector_hits, graph_hits)
        logging.info(f"Generated {len(merged)} merged results.")

        if merged:
            top_result = merged[0]
            logging.info(f"Top result score: {top_result.fused_score}")
            logging.info(f"Top result sources: {top_result.sources}")
        else:
            logging.warning("No merged results found. Ensure your database contains data matching your queries.")
            
    except Exception:
        logging.exception("❌ Error running integration test")
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test Vector and Graph retrieval with Reciprocal Rank Fusion.")
    parser.add_argument("--vector", type=str, default="GraphRAG", help="Query string for the Vector DB search")
    parser.add_argument("--graph", type=str, default="Microsoft Research", help="Entity name for the Graph DB query")
    
    args = parser.parse_args()
    test_integration(args.vector, args.graph)
