import json
import logging
import os
import re
from functools import lru_cache

import sentry_sdk
from openai import OpenAI

from backend.config import get_config
from backend.evaluation.lexical import (
    _CJK_RE,
    COMPARATOR_OPPOSITES,
    MULTILINGUAL_NEGATIONS,
    get_stopwords,
    is_meaningful_token,
    normalize_numbers as _normalize_numbers,
    pretokenize_cjk,
    stem_word as _stem,
)

logger = logging.getLogger(__name__)

# Default English stopwords for backward compatibility
STOPWORDS = get_stopwords("en", include_negations=False)


def _compute_lexical_claim_score(
    meaningful_tokens: list[str],
    context_tokens: set[str],
    context_stems: set[str],
    context_bigrams: set[tuple[str, str]],
) -> float:
    """Computes unigram and bigram alignment between meaningful claim tokens and context."""
    matches = sum(
        1 for w in meaningful_tokens if w in context_tokens or _stem(w) in context_stems
    )
    unigram_precision = matches / len(meaningful_tokens)

    sent_bigrams = [
        (meaningful_tokens[i], meaningful_tokens[i + 1])
        for i in range(len(meaningful_tokens) - 1)
    ]
    if sent_bigrams:
        bigram_matches = sum(1 for bg in sent_bigrams if bg in context_bigrams)
        bigram_precision = bigram_matches / len(sent_bigrams)
        return 0.7 * unigram_precision + 0.3 * bigram_precision
    return unigram_precision


def _apply_numeric_alignment_penalty(
    claim_score: float, sentence: str, context_text: str
) -> float:
    """Penalizes claims that assert specific numbers or percentages absent from the context."""
    raw_sent_numbers = re.findall(r"\b\d+(?:\.\d+)?%?\b", sentence.lower())
    sent_numbers = set(raw_sent_numbers)
    if not sent_numbers:
        return claim_score

    raw_context_numbers = re.findall(r"\b\d+(?:\.\d+)?%?\b", context_text.lower())
    context_numbers = set(raw_context_numbers)
    matched_numbers = sent_numbers & context_numbers
    num_ratio = len(matched_numbers) / len(sent_numbers)
    if num_ratio < 0.5:
        return min(claim_score, num_ratio * 0.4)
    return claim_score


def _find_best_matching_context_sentence(
    meaningful_set: set[str], raw_context_sentences: list[str]
) -> tuple[str, int]:
    """Finds the context sentence with maximum token overlap for fine-grained claim matching."""
    best_sent = ""
    best_overlap = 0
    for cs in raw_context_sentences:
        cs_tokens = set(w.lower() for w in re.findall(r"\w+", cs))
        overlap = len(meaningful_set & cs_tokens)
        if overlap > best_overlap:
            best_overlap = overlap
            best_sent = cs
    return best_sent, best_overlap


def _extract_comparator_local_anchors(
    sentence: str,
    comp: str,
    meaningful_set: set[str],
    claim_stems: set[str],
    window: int = 3,
) -> tuple[set[str], set[str]]:
    """Extracts meaningful anchor tokens from the claim within a local clause/token window of comp."""
    # Isolate clause containing comp if sentence has clause delimiters
    clauses = [c.strip() for c in re.split(r"[,;:—–]", sentence) if c.strip()]
    target_clause = sentence
    for clause in clauses:
        clause_words = [w.lower() for w in re.findall(r"\w+", clause)]
        if comp in clause_words:
            target_clause = clause
            break

    words = [w.lower() for w in re.findall(r"\w+", target_clause)]
    comp_positions = [idx for idx, w in enumerate(words) if w == comp]
    if not comp_positions:
        return meaningful_set, claim_stems

    local_words: set[str] = set()
    for pos in comp_positions:
        start = max(0, pos - window)
        end = min(len(words), pos + window + 1)
        for idx in range(start, end):
            if idx != pos and (words[idx] in meaningful_set or _stem(words[idx]) in claim_stems):
                local_words.add(words[idx])

    if not local_words:
        return meaningful_set, claim_stems

    local_stems = {_stem(w) for w in local_words if len(w) > 2}
    return local_words, local_stems


def _has_scoped_comparator_contradiction(
    sentence: str,
    tokens: list[str],
    meaningful_set: set[str],
    claim_stems: set[str],
    raw_context_sentences: list[str],
    max_token_distance: int = 4,
) -> bool:
    """
    Checks if a claim asserts a directional/temporal comparator whose opposite is asserted
    within proximity (<= max_token_distance) of the claim comparator's local anchor tokens
    in the context sentence.
    """
    sent_comps = [w for w in tokens if w in COMPARATOR_OPPOSITES]
    if not sent_comps:
        return False

    best_ctx_sent, best_overlap = _find_best_matching_context_sentence(
        meaningful_set, raw_context_sentences
    )
    if not best_ctx_sent or best_overlap < 2:
        return False

    best_ctx_tokens = [w.lower() for w in re.findall(r"\w+", best_ctx_sent)]

    for comp in sent_comps:
        local_anchors, local_stems = _extract_comparator_local_anchors(
            sentence, comp, meaningful_set, claim_stems, window=max_token_distance
        )
        opponents = COMPARATOR_OPPOSITES[comp]
        opp_indices = [idx for idx, w in enumerate(best_ctx_tokens) if w in opponents]
        ctx_local_match_indices = [
            idx
            for idx, w in enumerate(best_ctx_tokens)
            if w in local_anchors or _stem(w) in local_stems
        ]
        has_scoped_opp = any(
            abs(opp_i - m_i) <= max_token_distance
            for opp_i in opp_indices
            for m_i in ctx_local_match_indices
        )
        if has_scoped_opp and comp not in best_ctx_tokens:
            return True

    return False


def _has_scoped_negation_contradiction(
    sentence: str,
    tokens: list[str],
    meaningful_set: set[str],
    effective_stopwords: frozenset[str],
    context_text: str,
    claim_stems: set[str],
    raw_context_sentences: list[str],
) -> bool:
    """Verifies predicate-level and clause-level polarity to prevent negation hallucinations."""
    neg_words = MULTILINGUAL_NEGATIONS
    sent_has_neg = any(w in neg_words for w in tokens) or "n't" in sentence.lower()

    # Check predicate-level negation pairs: e.g. "not record", "never report"
    sent_words = [w.lower() for w in re.findall(r"\w+", sentence)]
    neg_pairs = []
    for i in range(len(sent_words) - 1):
        if (
            sent_words[i] in neg_words
            and sent_words[i + 1] not in effective_stopwords
            and sent_words[i + 1] not in neg_words
        ):
            neg_pairs.append((sent_words[i], sent_words[i + 1]))

    if neg_pairs:
        ctx_words = [w.lower() for w in re.findall(r"\w+", context_text)]
        ctx_pairs = set(
            (ctx_words[i], ctx_words[i + 1]) for i in range(len(ctx_words) - 1)
        )
        ctx_pairs_stemmed = set(
            (ctx_words[i], _stem(ctx_words[i + 1])) for i in range(len(ctx_words) - 1)
        )
        has_matching_neg = any(
            np in ctx_pairs or (np[0], _stem(np[1])) in ctx_pairs_stemmed
            for np in neg_pairs
        )
        if not has_matching_neg:
            return True
        return False

    best_ctx_sent, best_overlap = _find_best_matching_context_sentence(
        meaningful_set, raw_context_sentences
    )
    if best_overlap >= 2:
        best_ctx_tokens = [w.lower() for w in re.findall(r"\w+", best_ctx_sent)]
        ctx_neg_indices = [
            idx for idx, w in enumerate(best_ctx_tokens) if w in neg_words or "n't" in w
        ]
        ctx_match_indices = [
            idx
            for idx, w in enumerate(best_ctx_tokens)
            if w in meaningful_set or _stem(w) in claim_stems
        ]
        ctx_has_scoped_neg = bool(
            ctx_neg_indices
            and ctx_match_indices
            and any(
                abs(n_i - m_i) <= 2
                for n_i in ctx_neg_indices
                for m_i in ctx_match_indices
            )
        )
        if sent_has_neg != ctx_has_scoped_neg:
            return True

    return False


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

    # Strip citation and page metadata headers so metadata titles & numbers don't pollute context
    context_text = re.sub(
        r"\[Document:[^\]]*\]|<!--\s*page:\d+.*?-->",
        "",
        context_text,
        flags=re.IGNORECASE,
    ).strip()

    response_text = _normalize_numbers(pretokenize_cjk(response_text))
    context_text = _normalize_numbers(pretokenize_cjk(context_text))

    effective_stopwords = get_stopwords(
        text=f"{response_text} {context_text}", include_negations=False
    )

    # Tokenize context
    context_tokens = set(re.findall(r"\w+", context_text.lower()))
    context_stems = {_stem(t) for t in context_tokens if len(t) > 2}

    # Extract context bigrams and CJK compound tokens
    raw_ctx_words = [
        w.lower()
        for w in re.findall(r"\w+", context_text)
        if is_meaningful_token(w) and w.lower() not in effective_stopwords
    ]
    context_bigrams = set()
    for i in range(len(raw_ctx_words) - 1):
        context_bigrams.add((raw_ctx_words[i], raw_ctx_words[i + 1]))

    cjk_ctx = [w for w in raw_ctx_words if _CJK_RE.search(w)]
    for i in range(len(cjk_ctx) - 1):
        context_tokens.add(f"{cjk_ctx[i]}{cjk_ctx[i + 1]}")

    # Split context into sentences for fine-grained polarity matching (avoid splitting on decimal dots like 3.0x or 5.5%)
    raw_context_sentences = [
        cs.strip()
        for cs in re.split(r"(?<!\d)[.!?]+(?:\s+|$)|[\n]+", context_text)
        if cs.strip()
    ]

    # Split response into sentence claims
    sentences = [
        s.strip()
        for s in re.split(r"(?<!\d)[.!?]+(?:\s+|$)|[\n]+", response_text)
        if s.strip()
    ]
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

        tokens = [w.lower() for w in re.findall(r"\w+", sentence) if is_meaningful_token(w)]
        meaningful_tokens = [
            w for w in tokens if w not in effective_stopwords and w not in MULTILINGUAL_NEGATIONS
        ]
        if not meaningful_tokens:
            continue

        # For CJK, construct 2-character compound tokens so multi-character terms match reliably
        cjk_sent = [w for w in meaningful_tokens if _CJK_RE.search(w)]
        if len(cjk_sent) >= 2:
            for i in range(len(cjk_sent) - 1):
                meaningful_tokens.append(f"{cjk_sent[i]}{cjk_sent[i + 1]}")

        # Token matches (exact or stemmed)
        # 1. Lexical unigram and bigram alignment
        claim_score = _compute_lexical_claim_score(
            meaningful_tokens, context_tokens, context_stems, context_bigrams
        )

        # 2. Numeric and percentage alignment check
        claim_score = _apply_numeric_alignment_penalty(
            claim_score, sentence, context_text
        )

        # 3. Directional / quantitative comparator contradiction check
        meaningful_set = set(meaningful_tokens)
        claim_stems = {_stem(t) for t in meaningful_tokens if len(t) > 2}
        if _has_scoped_comparator_contradiction(
            sentence, tokens, meaningful_set, claim_stems, raw_context_sentences
        ):
            claim_score = min(claim_score, 0.25)

        # 4. Negation polarity check
        if _has_scoped_negation_contradiction(
            sentence,
            tokens,
            meaningful_set,
            effective_stopwords,
            context_text,
            claim_stems,
            raw_context_sentences,
        ):
            claim_score = min(claim_score, 0.25)

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

