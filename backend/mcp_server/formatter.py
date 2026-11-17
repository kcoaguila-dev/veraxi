import re
from collections.abc import Sequence
from typing import Any

from langchain_core.messages import BaseMessage, SystemMessage

from backend.prompts import CHAT_SYSTEM_PROMPT


def _extract_metrics_from_state(state: dict) -> dict[str, Any]:
    messages = state.get("messages") or []
    if not messages:
        return {}

    last_message = messages[-1]
    additional_kwargs = getattr(last_message, "additional_kwargs", {}) or {}
    metrics = additional_kwargs.get("metrics")
    if isinstance(metrics, dict):
        return metrics
    return {}


def _pricing_for_model(model_name: str | None) -> dict | None:
    """Return the operator-filled pricing entry for a model, or None."""
    if not model_name:
        return None
    from backend.models_config import MODEL_PRICING_USD_PER_1M_TOKENS

    entry = MODEL_PRICING_USD_PER_1M_TOKENS.get(model_name)
    if entry is None and "/" in model_name:
        entry = MODEL_PRICING_USD_PER_1M_TOKENS.get(model_name.split("/", 1)[1])
    return entry


def estimate_cost_usd(
    prompt_tokens: int, completion_tokens: int, model_name: str | None
) -> float | None:
    """Estimated USD cost, or None when the model has no pricing entry.

    Pricing comes only from the operator-filled
    ``MODEL_PRICING_USD_PER_1M_TOKENS`` table in models_config — when it
    has no entry for the model the cost is unknown (None), never an
    invented number.
    """
    entry = _pricing_for_model(model_name)
    if not entry:
        return None
    prompt_price = entry.get("prompt")
    completion_price = entry.get("completion")
    if not isinstance(prompt_price, (int, float)) or not isinstance(
        completion_price, (int, float)
    ):
        return None
    cost = (prompt_tokens / 1_000_000) * float(prompt_price) + (
        completion_tokens / 1_000_000
    ) * float(completion_price)
    return round(cost, 6)


def _token_value(usage: dict, *keys: str) -> int | None:
    for key in keys:
        value = usage.get(key)
        if isinstance(value, (int, float)):
            return int(value)
    return None


def shape_usage(usage: Any, model_name: str | None = None) -> dict[str, Any] | None:
    """Shape a provider usage object into display-ready token/cost fields.

    Accepts the shapes LiteLLM/LangChain surface (``prompt_tokens`` /
    ``completion_tokens`` / ``total_tokens`` or the LangChain
    ``input_tokens`` / ``output_tokens`` spellings). Returns None when
    usage is absent or carries no token counts — usage is never
    estimated or fabricated. ``estimated_cost_usd`` is None unless the
    operator has priced the model in models_config.
    """
    if not isinstance(usage, dict):
        return None
    prompt_tokens = _token_value(usage, "prompt_tokens", "input_tokens")
    completion_tokens = _token_value(usage, "completion_tokens", "output_tokens")
    total_tokens = _token_value(usage, "total_tokens")
    if prompt_tokens is None and completion_tokens is None and total_tokens is None:
        return None
    if total_tokens is None:
        total_tokens = (prompt_tokens or 0) + (completion_tokens or 0)
    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": total_tokens,
        "estimated_cost_usd": estimate_cost_usd(
            prompt_tokens or 0, completion_tokens or 0, model_name
        )
        if prompt_tokens is not None and completion_tokens is not None
        else None,
    }


def extract_usage_from_response(response: Any) -> dict[str, Any] | None:
    """Pull the raw usage dict off an LLM response, or None if absent.

    LangChain messages carry ``usage_metadata`` (input/output/total
    tokens); LiteLLM responses also mirror the provider payload in
    ``response_metadata`` under ``token_usage`` / ``usage``. Either may
    be missing (some providers/models report no usage) — then the
    completion simply has no usage, never an estimate.
    """
    usage_metadata = getattr(response, "usage_metadata", None)
    if isinstance(usage_metadata, dict) and usage_metadata:
        return usage_metadata
    response_metadata = getattr(response, "response_metadata", None) or {}
    if isinstance(response_metadata, dict):
        for key in ("token_usage", "usage"):
            candidate = response_metadata.get(key)
            if isinstance(candidate, dict) and candidate:
                return candidate
    return None


# Heuristic per-LLM-call token ranges for the Deep pre-flight estimate.
# These are planning ranges only (labelled as estimates in the API
# response); the call *counts* they multiply are derived from the
# debate workflow's actual configured limits.
_DEEP_PROMPT_TOKENS_PER_CALL = (1500, 6000)
_DEEP_COMPLETION_TOKENS_PER_CALL = (400, 2000)


def estimate_deep_usage(model_name: str | None = None) -> dict[str, Any]:
    """Pre-flight token-range estimate for Deep (agentic debate) mode.

    Call counts are derived from the configured debate limits in
    ``orchestrator_multi_agent``: each round is one writer + one
    skeptic LLM call, rounds run from 1 to ``DEBATE_MAX_ITERATIONS``,
    the specialist agents are retrieval-only, and the main chat model
    makes one final synthesis call. Token totals multiply those counts
    by the heuristic per-call ranges above — this is an estimate
    range, not a promise. Cost ranges appear only when the model is
    priced in models_config.
    """
    from backend.mcp_server.orchestrator_multi_agent import (
        DEBATE_LLM_CALLS_PER_ROUND,
        DEBATE_MAX_ITERATIONS,
        DEBATE_SPECIALIST_COUNT,
    )

    min_calls = DEBATE_LLM_CALLS_PER_ROUND + 1  # one round + final synthesis
    max_calls = DEBATE_LLM_CALLS_PER_ROUND * DEBATE_MAX_ITERATIONS + 1
    prompt_min = min_calls * _DEEP_PROMPT_TOKENS_PER_CALL[0]
    prompt_max = max_calls * _DEEP_PROMPT_TOKENS_PER_CALL[1]
    completion_min = min_calls * _DEEP_COMPLETION_TOKENS_PER_CALL[0]
    completion_max = max_calls * _DEEP_COMPLETION_TOKENS_PER_CALL[1]
    cost_min = estimate_cost_usd(prompt_min, completion_min, model_name)
    cost_max = estimate_cost_usd(prompt_max, completion_max, model_name)
    return {
        "mode": "deep",
        "is_estimate": True,
        "label": "Estimate only — actual usage depends on the debate rounds and retrieved evidence.",
        "model": model_name,
        "specialist_agents": DEBATE_SPECIALIST_COUNT,
        "max_rounds": DEBATE_MAX_ITERATIONS,
        "llm_calls": {"min": min_calls, "max": max_calls},
        "prompt_tokens": {"min": prompt_min, "max": prompt_max},
        "completion_tokens": {"min": completion_min, "max": completion_max},
        "total_tokens": {
            "min": prompt_min + completion_min,
            "max": prompt_max + completion_max,
        },
        "estimated_cost_usd": (
            {"min": cost_min, "max": cost_max}
            if cost_min is not None and cost_max is not None
            else None
        ),
    }


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    """Compute cosine similarity between two embedding vectors."""
    import numpy as np

    va = np.array(a, dtype=float)
    vb = np.array(b, dtype=float)
    norm_a = np.linalg.norm(va)
    norm_b = np.linalg.norm(vb)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(va, vb) / (norm_a * norm_b))


def _finalize_metrics(metrics: dict[str, Any]) -> dict[str, Any]:
    """Derive display-ready metric fields from raw telemetry collected during generation."""
    finalized = dict(metrics)

    # --- Token usage / cost (flattened so metrics stays scalar-valued) ---
    usage = finalized.pop("usage", None)
    if isinstance(usage, dict):
        for key in (
            "prompt_tokens",
            "completion_tokens",
            "total_tokens",
            "estimated_cost_usd",
        ):
            finalized[key] = usage.get(key)
    else:
        finalized.setdefault("prompt_tokens", None)
        finalized.setdefault("completion_tokens", None)
        finalized.setdefault("total_tokens", None)
        finalized.setdefault("estimated_cost_usd", None)

    # --- Context Adherence (grounding) ---
    grounding_score = finalized.get("grounding_score")
    if isinstance(grounding_score, (int, float)):
        finalized["context_adherence"] = round(float(grounding_score), 3)

    # --- Retrieval Relevance (cosine similarity, query ↔ context) ---
    retrieval_relevance: float | None = None
    query_emb = finalized.pop("query_embedding", None)
    context_emb = finalized.pop("context_embedding", None)
    if isinstance(query_emb, list) and isinstance(context_emb, list):
        retrieval_relevance = round(
            max(0.0, min(1.0, _cosine_similarity(query_emb, context_emb))), 3
        )
        finalized["retrieval_relevance"] = retrieval_relevance

    # --- Confidence (mean of available scores) ---
    score_candidates = [
        value
        for value in [finalized.get("context_adherence"), retrieval_relevance]
        if isinstance(value, (int, float))
    ]
    if score_candidates:
        finalized["confidence"] = round(
            sum(score_candidates) / len(score_candidates), 3
        )

    # --- Precision (harmonic mean / F1 of adherence & relevance) ---
    adherence = finalized.get("context_adherence")
    if isinstance(adherence, (int, float)) and isinstance(
        retrieval_relevance, (int, float)
    ):
        denom = float(adherence) + retrieval_relevance
        finalized["precision"] = (
            round((2 * float(adherence) * retrieval_relevance) / denom, 3)
            if denom > 0
            else 0.0
        )

    return finalized


def _sanitize_thread_title(raw_title: str) -> str:
    """Normalize model output into a sidebar-safe thread title."""
    title = raw_title.strip().strip("\"'").strip()
    title = title.split("\n", 1)[0].strip()
    title = re.sub(r"\s*\([^)]*\)\s*$", "", title).strip()
    if len(title) > 60:
        title = title[:57] + "..."
    return title


def _prepend_system_messages(
    messages: Sequence[BaseMessage],
    extra_system_messages: list[SystemMessage] | None = None,
    custom_system_prompt: str | None = None,
) -> list[BaseMessage]:
    """Inject chat-wide system instructions without persisting them to thread state."""
    system_messages = [SystemMessage(content=CHAT_SYSTEM_PROMPT)]

    if custom_system_prompt and custom_system_prompt.strip():
        system_messages.append(
            SystemMessage(
                content=f"USER CUSTOM INSTRUCTIONS:\n{custom_system_prompt.strip()}"
            )
        )

    if extra_system_messages:
        system_messages.extend(extra_system_messages)

    modified_messages = list(messages)
    for system_message in reversed(system_messages):
        modified_messages.insert(0, system_message)
    return modified_messages
