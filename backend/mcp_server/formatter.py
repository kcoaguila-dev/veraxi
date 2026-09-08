import re
from collections.abc import Sequence
from typing import Any

from backend.config import get_config
from backend.prompts import CHAT_SYSTEM_PROMPT
from langchain_core.messages import BaseMessage, SystemMessage
from langchain_openai import ChatOpenAI


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


def _finalize_metrics(metrics: dict[str, Any]) -> dict[str, Any]:
    """Derive display-ready metric fields from raw telemetry collected during generation."""
    finalized = dict(metrics)

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


def _create_chat_llm(model_name: str, api_key: str | None, base_url: str | None = None):
    """Build the configured chat LLM client for the active provider."""
    config = get_config()

    if config.is_enterprise:
        api_key = None
        base_url = None

    llm_args = config.get_llm_client_args(model_name=model_name)
    if api_key:
        llm_args["api_key"] = api_key
    if base_url:
        llm_args["base_url"] = base_url

    base_url = llm_args.get("base_url", "")
    if "api.groq.com" in base_url:
        from langchain_groq import ChatGroq

        groq_api_key = llm_args.pop("api_key", None)
        llm_args.pop("base_url", None)
        return ChatGroq(
            model=model_name,
            temperature=0,
            api_key=groq_api_key,
            **llm_args,
        )

    return ChatOpenAI(
        model=model_name,
        temperature=0,
        **llm_args,
    )


def _prepend_system_messages(
    messages: Sequence[BaseMessage],
    extra_system_messages: list[SystemMessage] | None = None,
) -> list[BaseMessage]:
    """Inject chat-wide system instructions without persisting them to thread state."""
    system_messages = [SystemMessage(content=CHAT_SYSTEM_PROMPT)]
    if extra_system_messages:
        system_messages.extend(extra_system_messages)

    modified_messages = list(messages)
    for system_message in reversed(system_messages):
        modified_messages.insert(0, system_message)
    return modified_messages


