import json
import logging
import os
import re
from functools import lru_cache

import sentry_sdk
from openai import OpenAI

from backend.config import get_config

logger = logging.getLogger(__name__)

STOPWORDS = {
    "a", "about", "above", "after", "again", "against", "all", "am", "an", "and",
    "any", "are", "aren't", "as", "at", "be", "because", "been", "before", "being",
    "below", "between", "both", "but", "by", "can", "cannot", "could", "did", "do",
    "does", "doing", "down", "during", "each", "few", "for", "from", "further", "had",
    "has", "have", "having", "he", "her", "here", "hers", "herself", "him", "himself",
    "his", "how", "i", "if", "in", "into", "is", "isn't", "it", "its", "itself",
    "me", "more", "most", "my", "myself", "no", "nor", "not", "of", "off", "on",
    "once", "only", "or", "other", "ought", "our", "ours", "ourselves", "out", "over",
    "own", "same", "she", "should", "so", "some", "such", "than", "that", "the",
    "their", "theirs", "them", "themselves", "then", "there", "these", "they", "this",
    "those", "through", "to", "too", "under", "until", "up", "very", "was", "wasn't",
    "we", "were", "weren't", "what", "when", "where", "which", "while", "who", "whom",
    "why", "with", "would", "you", "your", "yours", "yourself", "yourselves",
}


def _stem(word: str) -> str:
    return re.sub(r"(ing|ed|es|s|tion|ly)$", "", word.lower())


def evaluate_deterministic_grounding(response_text: str, context_text: str) -> float | None:
    """
    Tier 2: Fast, $0-cost deterministic grounding score between 0.0 and 1.0.
    Evaluates lexical containment, stemming, and bigram alignment between response and context.
    Returns None if response has no factual/content claims.
    """
    if not response_text or not response_text.strip():
        return None
    if not context_text or not context_text.strip():
        return 0.0

    # Tokenize context
    context_tokens = set(re.findall(r"\w+", context_text.lower()))
    context_stems = {_stem(t) for t in context_tokens if len(t) > 2}

    # Extract context bigrams
    raw_ctx_words = [
        w.lower()
        for w in re.findall(r"\w+", context_text)
        if len(w) >= 2 and w.lower() not in STOPWORDS
    ]
    context_bigrams = set()
    for i in range(len(raw_ctx_words) - 1):
        context_bigrams.add((raw_ctx_words[i], raw_ctx_words[i + 1]))

    # Split response into sentence claims
    sentences = [s.strip() for s in re.split(r"[.!?\n]+", response_text) if s.strip()]
    if not sentences:
        return None

    sentence_scores: list[float] = []

    # Clean context for substring check
    norm_context = re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", context_text.lower())).strip()

    for sentence in sentences:
        norm_sent = re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", sentence.lower())).strip()
        if not norm_sent:
            continue

        # If sentence is an exact normalized substring of the context, 100% grounded
        if norm_sent in norm_context:
            sentence_scores.append(1.0)
            continue

        tokens = [w.lower() for w in re.findall(r"\w+", sentence) if len(w) >= 2]
        meaningful_tokens = [w for w in tokens if w not in STOPWORDS]
        if not meaningful_tokens:
            continue

        # Token matches (exact or stemmed)
        matches = 0
        for w in meaningful_tokens:
            if w in context_tokens or _stem(w) in context_stems:
                matches += 1
        unigram_precision = matches / len(meaningful_tokens)

        # Bigram matches
        sent_bigrams = []
        for i in range(len(meaningful_tokens) - 1):
            sent_bigrams.append((meaningful_tokens[i], meaningful_tokens[i + 1]))

        if sent_bigrams:
            bigram_matches = sum(1 for bg in sent_bigrams if bg in context_bigrams)
            bigram_precision = bigram_matches / len(sent_bigrams)
            claim_score = 0.7 * unigram_precision + 0.3 * bigram_precision
        else:
            claim_score = unigram_precision

        sentence_scores.append(claim_score)

    if not sentence_scores:
        return None

    final_score = sum(sentence_scores) / len(sentence_scores)
    return round(max(0.0, min(1.0, final_score)), 4)


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
            logger.info(
                "Grounding evaluation found zero factual claims. Returning None to show N/A instead of misleading scores."
            )
            return None

        score = float(score_val)
        return max(0.0, min(1.0, score))
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Failed to parse grounding score: {e}")
        return 0.0


def _call_llm_for_grounding(
    config,
    context_text: str,
    response_text: str,
    api_key: str | None = None,
    model_name: str | None = None,
) -> float | None:
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
            {"role": "user", "content": user_message},
        ],
        response_format={"type": "json_object"},
        temperature=0.0,
    )

    return _parse_grounding_score(response.choices[0].message.content or "")


def evaluate_groundedness(
    response_text: str,
    context_text: str,
    api_key: str | None = None,
    model_name: str | None = None,
    method: str = "auto",
    require_byok: bool = False,
) -> float | None:
    """
    Tiered grounding evaluation:
    - method="deterministic":
        Fast, reproducible, $0 local computation.
    - method="llm":
        Deep semantic entailment via LLM.
        If require_byok=True and api_key is None, raises ValueError to prevent leaking server API budget.
    - method="auto":
        If api_key is provided -> uses LLM with user's key.
        If api_key is None and require_byok=True -> uses deterministic local scoring ($0 cost, 0 latency).
    """
    if not response_text or not response_text.strip():
        return None

    if not context_text or not context_text.strip():
        # If there is no context but there is a response, the score is 0.0 (unsupported)
        return 0.0

    normalized_method = (method or "auto").lower()

    # Option B: Deterministic local calculation requested
    if normalized_method == "deterministic":
        return evaluate_deterministic_grounding(response_text, context_text)

    # Option C: Enforce strict BYOK when require_byok=True
    if require_byok:
        if normalized_method == "llm" and not api_key:
            raise ValueError(
                "A user API key ('api_key') is required for LLM grounding evaluation to protect server resources (BYOK). "
                "Provide an 'api_key' or use method='deterministic' for free, local evaluation."
            )
        if normalized_method == "auto" and not api_key:
            # Default to deterministic: $0 cost, 0 latency, reliable!
            return evaluate_deterministic_grounding(response_text, context_text)

    # Otherwise (api_key provided, or internal legacy code with server config)
    config = get_config()
    try:
        return _call_llm_for_grounding(
            config, context_text, response_text, api_key=api_key, model_name=model_name
        )
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Error calculating LLM grounding score: {e}")
        return 0.0

