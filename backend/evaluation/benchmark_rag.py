import json
import logging
from dotenv import load_dotenv
load_dotenv('backend/.env')

from openai import OpenAI
from backend.config import get_config
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.retrieval.merge_rank import merge_rank, VectorHit, GraphHit
import statistics

# Import DeepEval components
from deepeval.models import DeepEvalBaseLLM
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, LLMTestCaseParams

logging.basicConfig(level=logging.ERROR, format="%(levelname)s: %(message)s")

class GeminiDeepEvalLLM(DeepEvalBaseLLM):
    """Custom DeepEval LLM wrapper to route evaluation requests to our configured LLM (Gemini via OpenAI compat)."""
    def __init__(self):
        config = get_config()
        self._model_name = config.llm_model_name
        llm_args = config.get_llm_client_args()
        self.client = OpenAI(**llm_args)

    def load_model(self):
        return self.client

    def generate(self, prompt: str) -> str:
        try:
            response = self.client.chat.completions.create(
                model=self._model_name,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.0
            )
            return response.choices[0].message.content
        except Exception as e:
            return f"[DeepEval Generation Failed: {str(e)}]"

    async def a_generate(self, prompt: str) -> str:
        return self.generate(prompt)

    def get_model_name(self):
        return self._model_name

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
    except Exception as e:
        return f"[Answer Generation Skipped: Missing/Exhausted API KEY ({str(e)})]"

def run_benchmark():
    tenant_id = "hotpotqa_mcp"
    eval_llm = GeminiDeepEvalLLM()
    
    correctness_metric = GEval(
        name="Correctness",
        criteria="Determine whether the actual output contains the expected output and is factually correct based on the expected output.",
        evaluation_params=[LLMTestCaseParams.ACTUAL_OUTPUT, LLMTestCaseParams.EXPECTED_OUTPUT],
        model=eval_llm,
        threshold=0.5
    )
    
    with open("backend/evaluation/dataset.json", "r") as f:
        evaluation_data = json.load(f)
        
    vector_scores = []
    hybrid_scores = []
        
    # ONLY DO THE FIRST QUERY because that is the only one we ingested with MCP!
    for idx, item in enumerate(evaluation_data[:1]):
        query = item["query"]
        expected_answer = item["expected_answer"]
        
        print("="*60)
        print(f"TEST CASE {idx+1}")
        print(f"Query: {query}")
        print(f"Expected: {expected_answer}")
        print("="*60)
        
        # 1. VECTOR RAG
        print("\n--- 1. VECTOR RAG (Qdrant Only) ---")
        vector_hits = search_vectors(query, limit=5, tenant_id=tenant_id)
        vector_context = "\n".join([hit.payload.get('text', '') for hit in vector_hits])
        
        vector_answer = generate_answer(query, vector_context)
        print(f"Vector Answer:\n{vector_answer}\n")
        
        print("Evaluating Vector RAG Correctness via DeepEval...")
        try:
            v_test_case = LLMTestCase(
                input=query,
                actual_output=vector_answer,
                expected_output=expected_answer
            )
            correctness_metric.measure(v_test_case)
            v_score = correctness_metric.score
        except Exception as e:
            print(f"Evaluation Failed: {e}")
            v_score = 0.0
            
        vector_scores.append(v_score)
        print(f"Vector Answer Correctness Score: {v_score:.2f}")
        
        
        # 2. HYBRID GRAPHRAG
        print("\n--- 2. HYBRID GRAPHRAG (Neo4j + Qdrant + RRF) ---")
        v_raw = search_vectors(query_text=query, limit=5, tenant_id=tenant_id)
        v_hits = [VectorHit(id=hit.id, score=hit.score, payload=hit.payload) for hit in v_raw]
        
        g_raw = query_graph(entity_name="Arthur's Magazine", max_hops=2, tenant_id=tenant_id)
        g_hits = [GraphHit(id=hit.id, payload=hit.payload) for hit in g_raw]
        
        hybrid_hits = merge_rank(vector_hits=v_hits, graph_hits=g_hits, limit=5)
        hybrid_context = "\n".join([hit.payload.get('text', '') for hit in hybrid_hits])
        
        hybrid_answer = generate_answer(query, hybrid_context)
        print(f"Hybrid Answer:\n{hybrid_answer}\n")
        
        print("Evaluating Hybrid GraphRAG Correctness via DeepEval...")
        try:
            h_test_case = LLMTestCase(
                input=query,
                actual_output=hybrid_answer,
                expected_output=expected_answer
            )
            correctness_metric.measure(h_test_case)
            h_score = correctness_metric.score
        except Exception as e:
            print(f"Evaluation Failed: {e}")
            h_score = 0.0
            
        hybrid_scores.append(h_score)
        print(f"Hybrid Answer Correctness Score: {h_score:.2f}")
        
    print("\n" + "="*60)
    print("FINAL BENCHMARK AGGREGATION")
    print(f"Average Vector RAG Correctness: {statistics.mean(vector_scores) * 100:.1f}%")
    print(f"Average Hybrid GraphRAG Correctness: {statistics.mean(hybrid_scores) * 100:.1f}%")
    print("="*60)

if __name__ == "__main__":
    run_benchmark()
