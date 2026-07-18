import json
import os
import pytest
from deepeval import assert_test
from deepeval.test_case import LLMTestCase
from deepeval.metrics import FaithfulnessMetric, ContextualPrecisionMetric, AnswerRelevancyMetric

from backend.mcp_server.llm_loop import answer_question
from backend.tests.custom_openai_eval import OpenAIDeepEvalModel

def get_test_cases():
    """Load dataset and generate Pytest parameters."""
    dataset_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "evaluation", "dataset.json")
    if not os.path.exists(dataset_path):
        return []
    
    with open(dataset_path, "r") as f:
        dataset = json.load(f)
        
    return dataset

@pytest.mark.parametrize("item", get_test_cases())
def test_rag_pipeline(item, mock_env):
    """
    Evaluates the RAG pipeline using DeepEval's LLM-as-a-judge (Gemini).
    Checks Context Precision, Faithfulness, and Answer Relevance.
    mock_env is used to ensure dummy variables are set if local .env is missing.
    """
    query = item["query"]
    tenant_id = item["tenant_id"]
    expected_output = item["expected_answer"]

    # Execute the RAG pipeline
    actual_output, context_str = answer_question(query, tenant_id=tenant_id, return_context=True)
    
    # We pass the context_str as a list of strings (retrieval context)
    retrieval_context = [context_str] if context_str else ["No context retrieved."]

    # Create DeepEval Test Case
    test_case = LLMTestCase(
        input=query,
        actual_output=actual_output,
        expected_output=expected_output,
        retrieval_context=retrieval_context,
    )

    # Initialize our custom OpenAI Judge
    openai_judge = OpenAIDeepEvalModel()

    # Define strict metrics
    faithfulness = FaithfulnessMetric(threshold=0.8, model=openai_judge)
    context_precision = ContextualPrecisionMetric(threshold=0.8, model=openai_judge)
    answer_relevancy = AnswerRelevancyMetric(threshold=0.8, model=openai_judge)

    # Run the assertions
    assert_test(test_case, [faithfulness, context_precision, answer_relevancy])
