import logging

from dotenv import load_dotenv

load_dotenv('backend/.env')

from openai import OpenAI

from backend.config import get_config
from backend.mcp_server.tools.evaluate_grounding import mcp_evaluate_grounding
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.retrieval.merge_rank import merge_rank

logging.basicConfig(level=logging.ERROR, format="%(levelname)s: %(message)s")

def generate_answer(query: str, context: str) -> str:
    config = get_config()
    llm_args = config.get_llm_client_args()
    client = OpenAI(**llm_args)
    
    prompt = f"Answer the following question using ONLY the provided context. If the context is insufficient, state that you cannot answer fully based on the context.\n\nContext:\n{context}\n\nQuestion:\n{query}"
    
    try:
        response = client.chat.completions.create(
            model=config.llm_model_name,
            messages=[{"role": "user", "content": prompt}],
            temperature=0.0
        )
        return response.choices[0].message.content
    except Exception as e:  # noqa: BLE001
        return f"[Answer Generation Skipped: Missing LLM_API_KEY ({e!s})]"

def run_benchmark():
    tenant_id = "default"
    
    # Complex multi-hop query requiring synthesis of different concepts
    query = "How do routers facilitate communication between different LAN topologies and the wider Internet?"
    
    print("="*50)
    print("BENCHMARKING RAG PIPELINES")
    print(f"Query: {query}")
    print("="*50)
    
    # 1. VECTOR RAG
    print("\n--- 1. VECTOR RAG (Qdrant Only) ---")
    vector_hits = search_vectors(query, limit=5, tenant_id=tenant_id)
    vector_context = "\n".join([hit.payload.get('text', '') for hit in vector_hits])
    
    print(f"Retrieved {len(vector_hits)} chunks.")
    vector_answer = generate_answer(query, vector_context)
    print(f"Answer:\n{vector_answer}\n")
    
    vector_score = mcp_evaluate_grounding(vector_answer, vector_context)
    print(f"RAGAS Faithfulness Score (Groundedness): {vector_score}")
    
    
    # 2. HYBRID GRAPHRAG
    print("\n--- 2. HYBRID GRAPHRAG (Neo4j + Qdrant + RRF) ---")
    hybrid_hits = merge_rank(tenant_id, query, "Computer network", limit=5, max_hops=2)
    
    # Hybrid hits return dicts containing 'text', 'source', 'score', etc.
    hybrid_context = "\n".join([hit.get('text', '') for hit in hybrid_hits])
    
    print(f"Retrieved {len(hybrid_hits)} chunks/nodes.")
    hybrid_answer = generate_answer(query, hybrid_context)
    print(f"Answer:\n{hybrid_answer}\n")
    
    hybrid_score = mcp_evaluate_grounding(hybrid_answer, hybrid_context)
    print(f"RAGAS Faithfulness Score (Groundedness): {hybrid_score}")
    
    print("\n" + "="*50)
    print("FINAL RESULTS")
    print(f"Vector RAG Score : {vector_score}")
    print(f"Hybrid GraphRAG  : {hybrid_score}")
    print("="*50)

if __name__ == "__main__":
    run_benchmark()
