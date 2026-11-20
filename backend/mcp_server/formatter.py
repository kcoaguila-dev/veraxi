import logging
import re
from collections.abc import Sequence
from functools import lru_cache
from typing import Any

from langchain_core.messages import BaseMessage, SystemMessage

from backend.prompts import CHAT_SYSTEM_PROMPT

logger = logging.getLogger(__name__)


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


def _usage_detail(
    usage: dict, top_level: tuple[str, ...], *nested: tuple[str, str]
) -> int | None:
    """Read a usage sub-count (cache / reasoning) across provider
    spellings: top-level keys first, then (parent, child) nests."""
    value = _token_value(usage, *top_level)
    if value is not None:
        return value
    for parent, child in nested:
        container = usage.get(parent)
        if isinstance(container, dict):
            value = _token_value(container, child)
            if value is not None:
                return value
    return None


@lru_cache(maxsize=128)
def context_window_tokens_for_model(model_name: str | None) -> int | None:
    """Context window size (max input tokens) for a model, or None.

    Resolved from LiteLLM's bundled model map — the same library that
    routes the call — so no extra dependency or network lookup is
    introduced. Unknown / unmapped models (custom endpoints, local
    GGUF, provider-specific aliases) return None: the UI then shows
    token counts without a percentage rather than a fabricated window.
    """
    if not model_name:
        return None
    try:
        import litellm

        info = litellm.get_model_info(model_name)
    except Exception:
        return None
    if not isinstance(info, dict):
        return None
    for key in ("max_input_tokens", "max_tokens"):
        value = info.get(key)
        if isinstance(value, (int, float)) and value > 0:
            return int(value)
    return None


def _http_get_json(url: str) -> Any:
    """GET a JSON document with a short timeout, or None on any failure."""
    try:
        import httpx

        response = httpx.get(url, timeout=2.0)
        if response.status_code != 200:
            return None
        return response.json()
    except Exception:
        return None


def _http_post_json(url: str, payload: dict) -> Any:
    """POST a JSON document with a short timeout, or None on any failure."""
    try:
        import httpx

        response = httpx.post(url, json=payload, timeout=2.0)
        if response.status_code != 200:
            return None
        return response.json()
    except Exception:
        return None


def _positive_int(value: Any) -> int | None:
    if isinstance(value, (int, float)) and value > 0:
        return int(value)
    return None


def _ollama_runtime_window(model_name: str, base_url: str) -> int | None:
    """Served context window from an Ollama endpoint's /api/show.

    ``num_ctx`` in the model's parameters is the window the server
    actually runs with, so it wins over the architecture's trained
    ``*.context_length`` when both are present.
    """
    root = base_url.rstrip("/").removesuffix("/v1")
    bare = model_name.split("/", 1)[-1]
    data = _http_post_json(f"{root}/api/show", {"name": bare})
    if not isinstance(data, dict):
        return None
    parameters = data.get("parameters")
    if isinstance(parameters, str):
        for line in parameters.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == "num_ctx":
                try:
                    window = _positive_int(float(parts[1]))
                except ValueError:
                    window = None
                if window is not None:
                    return window
    model_info = data.get("model_info")
    if isinstance(model_info, dict):
        for key, value in model_info.items():
            if key.endswith(".context_length"):
                window = _positive_int(value)
                if window is not None:
                    return window
    return None


def _openai_compat_runtime_window(model_name: str, base_url: str) -> int | None:
    """Served context window from an OpenAI-compatible /models listing.

    Covers the fields self-hosted servers actually publish: vLLM's
    ``max_model_len``, llama.cpp's ``meta.n_ctx`` (served) ahead of
    ``meta.n_ctx_train`` (trained), and generic ``context_length`` /
    ``max_context_length`` spellings.
    """
    data = _http_get_json(f"{base_url.rstrip('/')}/models")
    if not isinstance(data, dict):
        return None
    entries = data.get("data")
    if not isinstance(entries, list):
        return None
    bare = model_name.split("/", 1)[-1]
    entry = next(
        (
            e
            for e in entries
            if isinstance(e, dict) and e.get("id") in (model_name, bare)
        ),
        None,
    )
    if entry is None and len(entries) == 1 and isinstance(entries[0], dict):
        entry = entries[0]
    if entry is None:
        return None
    for key in ("max_model_len", "max_context_length", "context_length", "n_ctx"):
        window = _positive_int(entry.get(key))
        if window is not None:
            return window
    meta = entry.get("meta")
    if isinstance(meta, dict):
        for key in ("n_ctx", "n_ctx_train"):
            window = _positive_int(meta.get(key))
            if window is not None:
                return window
    return None


@lru_cache(maxsize=128)
def runtime_context_window_tokens(
    model_name: str | None, base_url: str | None
) -> int | None:
    """Context window the serving endpoint itself reports, or None.

    Only custom/self-hosted endpoints (those reached through an
    explicit base URL) are queried — the same destination the LLM call
    itself goes to, so no new host is contacted. Hosted provider APIs
    do not publish a served window this way; they fall back to the
    catalog. Any failure returns None: a percentage is shown only from
    a number a real source actually reported.
    """
    if not model_name or not base_url:
        return None
    if "11434" in base_url or model_name.startswith("ollama"):
        return _ollama_runtime_window(model_name, base_url)
    return _openai_compat_runtime_window(model_name, base_url)


def resolve_context_window_tokens(
    model_name: str | None, base_url: str | None = None
) -> int | None:
    """Best real context window for a model: runtime-reported first.

    A model can be served with a smaller window than its catalog
    maximum (Ollama ``num_ctx``, a vLLM ``--max-model-len`` cap), so
    when the endpoint itself reports a window it outranks LiteLLM's
    bundled map; the catalog is the fallback, and unknown models stay
    None rather than getting an invented denominator.
    """
    runtime = runtime_context_window_tokens(model_name, base_url)
    if runtime is not None:
        return runtime
    return context_window_tokens_for_model(model_name)


def shape_usage(
    usage: Any, model_name: str | None = None, base_url: str | None = None
) -> dict[str, Any] | None:
    """Shape a provider usage object into display-ready token/cost fields.

    Accepts the shapes LiteLLM/LangChain surface (``prompt_tokens`` /
    ``completion_tokens`` / ``total_tokens`` or the LangChain
    ``input_tokens`` / ``output_tokens`` spellings). Returns None when
    usage is absent or carries no token counts — usage is never
    estimated or fabricated. ``estimated_cost_usd`` is None unless the
    operator has priced the model in models_config.
    ``context_window_tokens`` is the model's context window — the
    serving endpoint's own reported window when it publishes one
    (custom base URL), else LiteLLM's model map, else None when the
    model is unmapped — the UI uses it as the denominator of its
    context-usage ring.
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
        # Cache + reasoning splits, when the provider reports them.
        # Spellings differ by source: LangChain usage_metadata nests
        # them under input_token_details/output_token_details;
        # LiteLLM mirrors OpenAI-style *_tokens_details plus
        # Anthropic-style top-level cache_*_input_tokens. All are
        # subsets of prompt/completion respectively — display-only,
        # never added into the totals.
        "cache_read_tokens": _usage_detail(
            usage,
            ("cache_read_input_tokens", "cache_read_tokens"),
            ("input_token_details", "cache_read"),
            ("prompt_tokens_details", "cached_tokens"),
        ),
        "cache_creation_tokens": _usage_detail(
            usage,
            ("cache_creation_input_tokens", "cache_creation_tokens"),
            ("input_token_details", "cache_creation"),
        ),
        "reasoning_tokens": _usage_detail(
            usage,
            ("reasoning_tokens",),
            ("output_token_details", "reasoning"),
            ("completion_tokens_details", "reasoning_tokens"),
        ),
        "estimated_cost_usd": estimate_cost_usd(
            prompt_tokens or 0, completion_tokens or 0, model_name
        )
        if prompt_tokens is not None and completion_tokens is not None
        else None,
        "context_window_tokens": resolve_context_window_tokens(
            model_name, base_url
        ),
    }


def _segment_text(content: Any) -> str:
    """Plain text of a message content (str or block list)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and isinstance(block.get("text"), str):
                parts.append(block["text"])
        return "".join(parts)
    return "" if content is None else str(content)


def _count_tokens(model_name: str | None, text: str) -> int:
    """Token count via LiteLLM's counter (already a dependency).

    Falls back to the gpt-4o (cl100k) tokenizer when the effective
    model is unknown to LiteLLM — segment counts are local counts by
    definition (the headline total stays provider-reported), so an
    approximate tokenizer for an unmapped model is acceptable here
    and only here. Raises if both fail; callers fail open.
    """
    if not text:
        return 0
    import litellm

    try:
        return int(litellm.token_counter(model=model_name, text=text))
    except Exception:
        return int(litellm.token_counter(model="gpt-4o", text=text))


def _serialize_tools_for_counting(tools: Sequence[Any] | None) -> str:
    """Name + description + arg-schema text for the bound tools.

    Approximates what the provider receives as tool definitions.
    Per-tool failures are skipped — a partial tools segment beats
    losing the whole breakdown.
    """
    if not tools:
        return ""
    parts: list[str] = []
    for tool in tools:
        try:
            if isinstance(tool, dict):
                parts.append(str(tool))
                continue
            name = getattr(tool, "name", "")
            description = getattr(tool, "description", "")
            schema = getattr(tool, "args_schema", None)
            schema_text = ""
            if schema is not None:
                json_schema = getattr(schema, "model_json_schema", None)
                schema_text = str(json_schema()) if callable(json_schema) else str(schema)
            parts.append(f"{name}\n{description}\n{schema_text}")
        except Exception:
            logger.debug("Skipping unserializable tool in segment counting", exc_info=True)
            continue
    return "\n".join(parts)


@lru_cache(maxsize=128)
def _count_static_segments(
    model_name: str | None, system_text: str, tools_text: str
) -> tuple[int, int]:
    """Cached counts for the rarely-changing system/tools segments."""
    return (
        _count_tokens(model_name, system_text),
        _count_tokens(model_name, tools_text),
    )


def count_context_segments(
    messages: Sequence[Any],
    tools: Sequence[Any] | None,
    model_name: str | None,
) -> dict[str, int] | None:
    """Split one request's context into system / tools / tool-results
    / messages token counts, or None when counting fails.

    These are *local counts* (LiteLLM's tokenizer for the effective
    model) taken at prompt-build time — they explain what fills the
    window; they never replace the provider-reported prompt total.
    Retrieval (RAG) content reaches the model as ToolMessages in
    Veraxi, so it lands in ``tool_results``. Any failure returns None
    (fail-open: a missing breakdown must never break a chat request).
    """
    try:
        system_parts: list[str] = []
        tool_result_parts: list[str] = []
        dialogue_parts: list[str] = []
        for message in messages or []:
            text = _segment_text(getattr(message, "content", ""))
            if not text:
                continue
            message_type = getattr(message, "type", "")
            if message_type == "system":
                system_parts.append(text)
            elif message_type == "tool":
                tool_result_parts.append(text)
            else:
                dialogue_parts.append(text)
        system_tokens, tools_tokens = _count_static_segments(
            model_name,
            "\n".join(system_parts),
            _serialize_tools_for_counting(tools),
        )
        return {
            "system": system_tokens,
            "tools": tools_tokens,
            "tool_results": _count_tokens(model_name, "\n".join(tool_result_parts)),
            "messages": _count_tokens(model_name, "\n".join(dialogue_parts)),
        }
    except Exception:
        return None


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
            "context_window_tokens",
            "cache_read_tokens",
            "cache_creation_tokens",
            "reasoning_tokens",
        ):
            finalized[key] = usage.get(key)
    else:
        finalized.setdefault("prompt_tokens", None)
        finalized.setdefault("completion_tokens", None)
        finalized.setdefault("total_tokens", None)
        finalized.setdefault("estimated_cost_usd", None)
        finalized.setdefault("context_window_tokens", None)
        finalized.setdefault("cache_read_tokens", None)
        finalized.setdefault("cache_creation_tokens", None)
        finalized.setdefault("reasoning_tokens", None)

    # --- Context breakdown (local segment counts, flattened likewise) ---
    breakdown = finalized.pop("context_breakdown", None)
    if isinstance(breakdown, dict):
        finalized["context_system_tokens"] = breakdown.get("system")
        finalized["context_tools_tokens"] = breakdown.get("tools")
        finalized["context_tool_results_tokens"] = breakdown.get("tool_results")
        finalized["context_messages_tokens"] = breakdown.get("messages")
    else:
        finalized.setdefault("context_system_tokens", None)
        finalized.setdefault("context_tools_tokens", None)
        finalized.setdefault("context_tool_results_tokens", None)
        finalized.setdefault("context_messages_tokens", None)

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
