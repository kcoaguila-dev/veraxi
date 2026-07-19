import json
import logging
from openai import OpenAI
from backend.config import get_config

logger = logging.getLogger(__name__)

GROUNDING_PROMPT = """
You are an expert evaluator. Your task is to calculate a Grounding Score (a float between 0.0 and 1.0) 
for a given response based strictly on the provided context.

To calculate the score:
1. Extract all factual claims made in the response.
2. For each claim, check if it is explicitly supported by the context.
3. Calculate the score as: (Number of supported claims) / (Total number of claims).
4. If there are no factual claims, return a score of 1.0.

Return ONLY a valid JSON object with the following schema, and no other text:
{
    "score": 0.85,
    "reasoning": "Brief explanation of which claims were supported and which were not."
}
"""

def evaluate_groundedness(response_text: str, context_text: str) -> float:
    """
    Evaluates how much of the response_text is supported by context_text.
    Returns a score between 0.0 and 1.0.
    """
    if not response_text or not response_text.strip():
        return 1.0

    if not context_text or not context_text.strip():
        # If there is no context but there is a response, the score is 0.0 (unsupported)
        return 0.0

    config = get_config()
    client_args = {}
    if config.llm_api_key:
        client_args["api_key"] = config.llm_api_key
    if config.llm_base_url:
        client_args["base_url"] = config.llm_base_url
        
    try:
        user_message = (
            f"Context:\n{context_text}\n\n"
            f"Response:\n{response_text}"
        )
        client = OpenAI(**client_args)

        response = client.chat.completions.create(
            model=config.llm_model_name,
            messages=[
                {"role": "system", "content": GROUNDING_PROMPT},
                {"role": "user", "content": user_message}
            ],
            response_format={"type": "json_object"},
            temperature=0.0
        )
        
        result_content = response.choices[0].message.content
        if not result_content:
            return 0.0
            
        result_json = json.loads(result_content)
        score = float(result_json.get("score", 0.0))
        
        # Ensure score is within bounds
        return max(0.0, min(1.0, score))
    except Exception as e:
        logger.error(f"Error calculating grounding score: {e}")
        # In case of evaluation failure, we return 0.0 to fail safely
        return 0.0
