"""
Veraxi Hybrid GraphRAG Benchmark Suite.

Runs Vector RAG vs Hybrid GraphRAG (Neo4j + Qdrant + RRF) on a test corpus,
scores both with DeepEval's GEval (LLM-as-a-judge), and writes results to
backend/evaluation/results.json.

Requires:
  - Neo4j and Qdrant populated with the test corpus (run manual_ingest.py first)
  - A valid LLM_API_KEY in backend/.env
  - DeepEval installed (pip install deepeval)
"""
import json
import logging
import time

from dotenv import load_dotenv

load_dotenv('backend/.env')

import statistics

from backend.config import get_config
from backend.mcp_server.tools.query_graph import query_graph
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.retrieval.merge_rank import GraphHit, VectorHit, merge_rank
from deepeval.metrics import GEval

# Import DeepEval components
from deepeval.models import DeepEvalBaseLLM
from deepeval.test_case import LLMTestCase, LLMTestCaseParams
from openai import OpenAI

logging.basicConfig(level=logging.ERROR, format="%(levelname)s: %(message)s")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
MAX_RETRIES = 3
RETRY_BASE_DELAY_S = 60  # Gemini free tier asks for ~60s backoff


class GeminiDeepEvalLLM(DeepEvalBaseLLM):
    """Custom DeepEval LLM wrapper that routes evaluation to the configured LLM."""

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
        except Exception as e:  # noqa: BLE001
            return f"[DeepEval Generation Failed: {e!s}]"

    async def a_generate(self, prompt: str) -> str:
        return self.generate(prompt)

    def get_model_name(self):
        return self._model_name


def _call_llm_with_retry(client, model: str, prompt: str) -> str | None:
    """Call the LLM with exponential backoff on 429 errors.

    Returns the answer string on success, or None if all retries are exhausted.
    """
    for attempt in range(MAX_RETRIES):
        try:
            response = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.0
            )
            return response.choices[0].message.content
        except Exception as e:  # noqa: BLE001
            if "429" in str(e) or "RESOURCE_EXHAUSTED" in str(e):
                delay = RETRY_BASE_DELAY_S * (attempt + 1)
                print(f"  Rate-limited (attempt {attempt + 1}/{MAX_RETRIES}). Retrying in {delay}s...")
                time.sleep(delay)
            else:
                print(f"  LLM error: {e!s}")
                return None
    return None


def generate_answer(query: str, context: str) -> str | None:
    """Generate a RAG answer using the configured LLM.

    Returns the answer string, or None on failure (so callers can skip scoring).
    """
    config = get_config()
    llm_args = config.get_llm_client_args()
    client = OpenAI(**llm_args)

    prompt = (
        "Answer the following question using ONLY the provided context. "
        "If the context is insufficient, state that you cannot answer fully "
        "based on the context.\n\n"
        f"Context:\n{context}\n\n"
        f"Question:\n{query}"
    )

    return _call_llm_with_retry(client, config.llm_model_name, prompt)


def _evaluate_correctness(metric, query: str, actual: str, expected: str) -> float | None:
    """Run DeepEval GEval scoring. Returns the score, or None on failure."""
    try:
        test_case = LLMTestCase(
            input=query,
            actual_output=actual,
            expected_output=expected
        )
        metric.measure(test_case)
        return metric.score
    except Exception as e:  # noqa: BLE001
        print(f"  Evaluation failed: {e}")
        return None


def run_benchmark():
    tenant_id = "benchmark"
    eval_llm = GeminiDeepEvalLLM()

    correctness_metric = GEval(
        name="Correctness",
        criteria=(
            "Determine whether the actual output contains the expected output "
            "and is factually correct based on the expected output."
        ),
        evaluation_params=[LLMTestCaseParams.ACTUAL_OUTPUT, LLMTestCaseParams.EXPECTED_OUTPUT],
        model=eval_llm,
        threshold=0.5
    )

    with open("backend/evaluation/dataset.json", "r") as f:
        evaluation_data = json.load(f)

    benchmark_results = []

    for idx, item in enumerate(evaluation_data):
        query = item["query"]
        expected_answer = item["expected_answer"]
        entity = item.get("entity", "Basal cell carcinoma")

        print("=" * 60)
        print(f"TEST CASE {idx + 1}")
        print(f"Query: {query}")
        print(f"Expected: {expected_answer}")
        print("=" * 60)

        result_entry = {"query": query, "vector_score": None, "hybrid_score": None, "status": "skipped"}

        # --- 1. VECTOR RAG ---
        print("\n--- 1. VECTOR RAG (Qdrant Only) ---")
        vector_hits = search_vectors(query, limit=5, tenant_id=tenant_id)
        vector_context = "\n".join([hit.payload.get('text', '') for hit in vector_hits])

        vector_answer = generate_answer(query, vector_context)
        v_score = None
        if vector_answer:
            print(f"Vector Answer:\n{vector_answer}\n")
            v_score = _evaluate_correctness(correctness_metric, query, vector_answer, expected_answer)
            if v_score is not None:
                print(f"Vector Correctness Score: {v_score:.2f}")
            else:
                print("Vector scoring failed (eval LLM error).")
        else:
            print("Vector answer generation failed (API quota exhausted).")

        # --- 2. HYBRID GRAPHRAG ---
        print("\n--- 2. HYBRID GRAPHRAG (Neo4j + Qdrant + RRF) ---")
        v_raw = search_vectors(query_text=query, limit=5, tenant_id=tenant_id)
        v_hits = [VectorHit(id=hit.id, score=hit.score, payload=hit.payload) for hit in v_raw]

        g_raw = query_graph(entity_name=entity, max_hops=2, tenant_id=tenant_id)
        g_hits = [GraphHit(id=hit.id, payload=hit.payload) for hit in g_raw]

        hybrid_hits = merge_rank(vector_hits=v_hits, graph_hits=g_hits, limit=5)
        hybrid_context = "\n".join([hit.payload.get('text', '') for hit in hybrid_hits])

        hybrid_answer = generate_answer(query, hybrid_context)
        h_score = None
        if hybrid_answer:
            print(f"Hybrid Answer:\n{hybrid_answer}\n")
            h_score = _evaluate_correctness(correctness_metric, query, hybrid_answer, expected_answer)
            if h_score is not None:
                print(f"Hybrid Correctness Score: {h_score:.2f}")
            else:
                print("Hybrid scoring failed (eval LLM error).")
        else:
            print("Hybrid answer generation failed (API quota exhausted).")

        if v_score is not None and h_score is not None:
            result_entry["status"] = "scored"
        elif v_score is not None or h_score is not None:
            result_entry["status"] = "partial"

        result_entry["vector_score"] = v_score
        result_entry["hybrid_score"] = h_score
        benchmark_results.append(result_entry)

        print("Sleeping for 15s to respect API rate limits...")
        time.sleep(15)

    # --- AGGREGATION ---
    scored_vector = [r["vector_score"] for r in benchmark_results if r["vector_score"] is not None]
    scored_hybrid = [r["hybrid_score"] for r in benchmark_results if r["hybrid_score"] is not None]

    avg_vector = statistics.mean(scored_vector) if scored_vector else 0
    avg_hybrid = statistics.mean(scored_hybrid) if scored_hybrid else 0
    scored_count = sum(1 for r in benchmark_results if r["status"] == "scored")
    total_count = len(benchmark_results)

    print("\n" + "=" * 60)
    print("FINAL BENCHMARK AGGREGATION")
    print(f"Scored test cases: {scored_count}/{total_count}")
    print(f"Average Vector RAG Correctness: {avg_vector * 100:.1f}%  (n={len(scored_vector)})")
    print(f"Average Hybrid GraphRAG Correctness: {avg_hybrid * 100:.1f}%  (n={len(scored_hybrid)})")
    print("=" * 60)

    final_output = {
        "summary": {
            "average_vector_correctness": round(avg_vector, 4),
            "average_hybrid_correctness": round(avg_hybrid, 4),
            "scored_test_cases": scored_count,
            "total_test_cases": total_count
        },
        "details": benchmark_results
    }

    with open("backend/evaluation/results.json", "w") as f:
        json.dump(final_output, f, indent=4)

    print("Results saved to backend/evaluation/results.json")


if __name__ == "__main__":
    run_benchmark()
