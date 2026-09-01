import json
import logging
import os
from functools import lru_cache

import sentry_sdk
from openai import OpenAI

from backend.config import get_config

logger = logging.getLogger(__name__)

@lru_cache(maxsize=1)
def _load_prompt() -> str:
    prompt_path = os.path.join(os.path.dirname(__file__), "grounding_prompt.txt")
    with open(prompt_path, "r", encoding="utf-8") as f:
        return f.read()

def _parse_grounding_score(result_content: str) -> float | None:
    if not result_content:
        return 0.0
    logger.info(f"Grounding result content: {result_content}")
    try:
        result_json = json.loads(result_content)
        score_val = result_json.get("score")
        
        if score_val is None:
            logger.info("Grounding evaluation found zero factual claims. Returning None to show N/A instead of misleading scores.")
            return None
            
        score = float(score_val)
        return max(0.0, min(1.0, score))
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Failed to parse grounding score: {e}")
        return 0.0

def _call_llm_for_grounding(config, context_text: str, response_text: str, api_key: str | None = None, model_name: str | None = None) -> float:
    user_message = f"Context:\n{context_text}\n\nResponse:\n{response_text}"
    
    effective_model = model_name or config.llm_model_name
    llm_args = config.get_llm_client_args(model_name=effective_model)
    
    effective_api_key = api_key or llm_args.get("api_key")
    if effective_api_key:
        llm_args["api_key"] = effective_api_key
        
    client = OpenAI(**llm_args)

    response = client.chat.completions.create(
        model=effective_model,
        messages=[
            {"role": "system", "content": _load_prompt()},
            {"role": "user", "content": user_message}
        ],
        response_format={"type": "json_object"},
        temperature=0.0
    )
    
    return _parse_grounding_score(response.choices[0].message.content)

def evaluate_groundedness(response_text: str, context_text: str, api_key: str | None = None, model_name: str | None = None) -> float | None:
    """
    Evaluates how much of the response_text is supported by context_text.
    Returns a score between 0.0 and 1.0.
    """
    if not response_text or not response_text.strip():
        return None

    if not context_text or not context_text.strip():
        # If there is no context but there is a response, the score is 0.0 (unsupported)
        return 0.0

    config = get_config()
    try:
        return _call_llm_for_grounding(config, context_text, response_text, api_key=api_key, model_name=model_name)
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error calculating grounding score: {e}")
        # In case of evaluation failure, we return 0.0 to fail safely
        return 0.0
