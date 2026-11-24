"""Unified thinking/reasoning capability registry and payload translator.

Single source of truth for:
- Mapping Veraxi's canonical thinking levels (``off``, ``minimal``, ``low``,
  ``medium``, ``high``, ``max``, ``on``) to provider-native LiteLLM
  ``model_kwargs`` and safe sampling parameters (especially ``temperature``).
- Exposing per-model capabilities for ``GET /api/models/capabilities`` so the
  Flutter UI only offers levels the selected model actually supports.
- Probing local runtimes (Ollama ``/api/show``, llama.cpp ``/props``,
  LM Studio ``/api/v0/models``) with short timeouts and TTL caching.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from functools import lru_cache
from typing import Any, Literal
from urllib.parse import urlparse

import httpx
import litellm

logger = logging.getLogger(__name__)

ThinkingMode = Literal[
    "none", "unknown", "toggle", "effort", "adaptive_effort", "level", "budget"
]
CanonicalLevel = Literal["off", "minimal", "low", "medium", "high", "max", "on"]

CANONICAL_LEVELS: tuple[str, ...] = (
    "off",
    "minimal",
    "low",
    "medium",
    "high",
    "max",
    "on",
)

_BUDGET_TOKENS_BY_LEVEL: dict[str, int] = {
    "minimal": 1024,
    "low": 2048,
    "medium": 8192,
    "high": 24576,
    "max": 32768,
    "on": 8192,
}

_LOCAL_PROBE_TTL_SECONDS = 300.0
_local_probe_cache: dict[str, tuple[float, LocalRuntimeProbe]] = {}


@dataclass(frozen=True)
class ThinkingCapability:
    """Describes what thinking/reasoning controls a model supports."""

    mode: ThinkingMode
    levels: tuple[str, ...]
    default_level: str | None
    temp_when_off: float | None = 0.0
    temp_when_thinking: float | None = None
    runtime: str | None = None

    @property
    def supports_reasoning(self) -> bool:
        return self.mode not in ("none", "unknown") and len(self.levels) > 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "mode": self.mode,
            "levels": list(self.levels),
            "default_level": self.default_level,
            "supports_reasoning": self.supports_reasoning,
            **({"runtime": self.runtime} if self.runtime else {}),
        }


class UnsupportedThinkingLevelError(ValueError):
    """Raised when a caller requests a thinking level the model does not support."""

    def __init__(
        self,
        model_name: str,
        requested_level: str,
        supported_levels: tuple[str, ...],
    ) -> None:
        self.model_name = model_name
        self.requested_level = requested_level
        self.supported_levels = supported_levels
        if not supported_levels:
            msg = (
                f"Model '{model_name}' does not support thinking levels "
                f"(requested '{requested_level}')."
            )
        else:
            opts = ", ".join(supported_levels)
            msg = (
                f"Model '{model_name}' does not support thinking level "
                f"'{requested_level}'. Supported levels: [{opts}]."
            )
        super().__init__(msg)


@dataclass(frozen=True)
class ThinkingTranslation:
    """Provider-ready LiteLLM kwargs and safe sampling overrides."""

    model_kwargs: dict[str, Any]
    temperature: float | None
    max_tokens_min: int | None
    effective_level: str | None
    clamped_from: str | None = None


@dataclass(frozen=True)
class LocalRuntimeProbe:
    """Cached capability probe result for a self-hosted local server."""

    runtime: str  # "ollama" | "llamacpp" | "vllm" | "lmstudio" | "openai_compat"
    model_capabilities: dict[str, ThinkingCapability]


_NO_THINKING = ThinkingCapability(
    mode="none",
    levels=(),
    default_level=None,
    temp_when_off=0.0,
    temp_when_thinking=None,
)

_UNKNOWN_THINKING = ThinkingCapability(
    mode="unknown",
    levels=(),
    default_level=None,
    temp_when_off=0.0,
    temp_when_thinking=None,
)

_OPENAI_GPT5_CAP = ThinkingCapability(
    mode="effort",
    levels=("off", "minimal", "low", "medium", "high", "max"),
    default_level="medium",
    temp_when_off=0.0,
    temp_when_thinking=None,
)

_OPENAI_GPT5_PRO_CAP = ThinkingCapability(
    mode="effort",
    levels=("low", "medium", "high", "max"),
    default_level="medium",
    temp_when_off=None,
    temp_when_thinking=None,
)

_OPENAI_O_SERIES_CAP = ThinkingCapability(
    mode="effort",
    levels=("low", "medium", "high"),
    default_level="medium",
    temp_when_off=None,
    temp_when_thinking=None,
)

_ANTHROPIC_ADAPTIVE_CAP = ThinkingCapability(
    mode="adaptive_effort",
    levels=("off", "low", "medium", "high", "max"),
    default_level="medium",
    temp_when_off=0.0,
    temp_when_thinking=None,
)

_ANTHROPIC_BUDGET_CAP = ThinkingCapability(
    mode="budget",
    levels=("off", "low", "medium", "high"),
    default_level="medium",
    temp_when_off=0.0,
    temp_when_thinking=None,
)

_GEMINI_3_FLASH_CAP = ThinkingCapability(
    mode="level",
    levels=("minimal", "low", "medium", "high"),
    default_level="medium",
    temp_when_off=None,
    temp_when_thinking=None,
)

_GEMINI_3_PRO_CAP = ThinkingCapability(
    mode="level",
    levels=("low", "medium", "high"),
    default_level="medium",
    temp_when_off=None,
    temp_when_thinking=None,
)

_GEMINI_25_FLASH_CAP = ThinkingCapability(
    mode="budget",
    levels=("off", "low", "medium", "high"),
    default_level="medium",
    temp_when_off=0.0,
    temp_when_thinking=None,
)

_GEMINI_25_PRO_CAP = ThinkingCapability(
    mode="budget",
    levels=("low", "medium", "high"),
    default_level="medium",
    temp_when_off=None,
    temp_when_thinking=None,
)

_DEEPSEEK_ALWAYS_ON_CAP = ThinkingCapability(
    mode="toggle",
    levels=("on",),
    default_level="on",
    temp_when_off=None,
    temp_when_thinking=None,
)

_DEEPSEEK_TOGGLE_CAP = ThinkingCapability(
    mode="toggle",
    levels=("off", "on"),
    default_level="off",
    temp_when_off=0.0,
    temp_when_thinking=0.6,
)

_GROQ_GPT_OSS_CAP = ThinkingCapability(
    mode="effort",
    levels=("low", "medium", "high"),
    default_level="medium",
    temp_when_off=None,
    temp_when_thinking=None,
)

_LOCAL_TOGGLE_CAP = ThinkingCapability(
    mode="toggle",
    levels=("off", "on"),
    default_level="on",
    temp_when_off=0.0,
    temp_when_thinking=0.6,
)

_LOCAL_EFFORT_CAP = ThinkingCapability(
    mode="effort",
    levels=("off", "low", "medium", "high"),
    default_level="medium",
    temp_when_off=0.0,
    temp_when_thinking=0.6,
)

_LOCAL_REASONING_NAME_MARKERS = (
    "qwen3",
    "qwq",
    "deepseek-r1",
    "deepseek-reasoner",
    "r1-distill",
    "magistral",
    "phi-4-reasoning",
    "cogito",
    "kimi-k2",
)


def _strip_provider_prefix(model_name: str) -> tuple[str | None, str]:
    """Return ``(provider_prefix, bare_model_name)`` in lowercase."""
    raw = (model_name or "").strip().lower()
    for prefix in (
        "groq/",
        "openai/",
        "anthropic/",
        "gemini/",
        "deepseek/",
        "mistral/",
        "moonshot/",
        "ollama_chat/",
        "ollama/",
        "openrouter/",
    ):
        if raw.startswith(prefix):
            return prefix.rstrip("/"), raw[len(prefix) :]
    return None, raw


def _resolve_openai_capability(bare: str) -> ThinkingCapability:
    if bare.startswith(("gpt-4", "gpt-3.5", "davinci", "babbage")):
        return _NO_THINKING
    if "chat-latest" in bare or bare.endswith("-chat"):
        return _NO_THINKING
    if bare.startswith(("o1", "o3", "o4")):
        return _OPENAI_O_SERIES_CAP
    if bare.startswith("gpt-5"):
        if "-pro" in bare:
            return _OPENAI_GPT5_PRO_CAP
        return _OPENAI_GPT5_CAP
    return _NO_THINKING


@lru_cache(maxsize=64)
def _anthropic_supports_max(bare: str) -> bool:
    """Ask LiteLLM's Anthropic validator whether ``effort='max'`` is allowed."""
    try:
        from litellm.llms.anthropic.chat.transformation import AnthropicConfig

        validator = getattr(
            AnthropicConfig,
            "validate_effort_for_model",
            getattr(AnthropicConfig, "_validate_effort_for_model", None),
        )
        if validator is None:
            return True
        return validator(bare, "max", "anthropic") is None
    except Exception:
        return True


def _resolve_anthropic_capability(bare: str) -> ThinkingCapability:
    if bare.startswith(("claude-3-5", "claude-3-opus", "claude-3-sonnet", "claude-3-haiku")):
        return _NO_THINKING
    if bare.startswith(("claude-3-7", "claude-opus-4-2025", "claude-sonnet-4-2025")):
        return _ANTHROPIC_BUDGET_CAP
    if bare.startswith(("claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6")):
        if _anthropic_supports_max(bare):
            return _ANTHROPIC_ADAPTIVE_CAP
        return ThinkingCapability(
            mode="adaptive_effort",
            levels=("off", "low", "medium", "high"),
            default_level="medium",
            temp_when_off=0.0,
            temp_when_thinking=None,
        )
    return _NO_THINKING


def _resolve_gemini_capability(bare: str) -> ThinkingCapability:
    if bare.startswith("gemini-3"):
        if "pro" in bare:
            return _GEMINI_3_PRO_CAP
        return _GEMINI_3_FLASH_CAP
    if bare.startswith("gemini-2.5"):
        if "pro" in bare:
            return _GEMINI_25_PRO_CAP
        return _GEMINI_25_FLASH_CAP
    return _NO_THINKING


def _resolve_local_heuristic(bare: str, runtime: str | None = None) -> ThinkingCapability:
    if "gpt-oss" in bare:
        return ThinkingCapability(
            mode="effort",
            levels=("low", "medium", "high"),
            default_level="medium",
            temp_when_off=None,
            temp_when_thinking=None,
            runtime=runtime,
        )
    if any(marker in bare for marker in _LOCAL_REASONING_NAME_MARKERS):
        base = _LOCAL_EFFORT_CAP if runtime == "llamacpp" else _LOCAL_TOGGLE_CAP
        return ThinkingCapability(
            mode=base.mode,
            levels=base.levels,
            default_level=base.default_level,
            temp_when_off=base.temp_when_off,
            temp_when_thinking=base.temp_when_thinking,
            runtime=runtime,
        )
    return ThinkingCapability(
        mode="none",
        levels=(),
        default_level=None,
        temp_when_off=0.0,
        temp_when_thinking=None,
        runtime=runtime,
    )


def get_cached_local_probe(base_url: str | None) -> LocalRuntimeProbe | None:
    """Return a non-expired ``LocalRuntimeProbe`` for ``base_url``, if cached."""
    if not base_url:
        return None
    origin = _origin_from_base_url(base_url)
    cached = _local_probe_cache.get(origin)
    if cached and (time.time() - cached[0]) < _LOCAL_PROBE_TTL_SECONDS:
        return cached[1]
    return None


def resolve_thinking_capability(
    model_name: str,
    base_url: str | None = None,
    runtime_probe: LocalRuntimeProbe | None = None,
) -> ThinkingCapability:
    """Determine thinking capabilities for a cloud or local model."""
    if not model_name or model_name == "Select a model":
        return _NO_THINKING

    prefix, bare = _strip_provider_prefix(model_name)
    effective_probe = runtime_probe or get_cached_local_probe(base_url)

    if effective_probe is not None:
        probed = effective_probe.model_capabilities.get(
            model_name
        ) or effective_probe.model_capabilities.get(bare)
        if probed is not None:
            return probed

    if base_url or prefix in ("ollama", "ollama_chat"):
        runtime = effective_probe.runtime if effective_probe else (
            "ollama" if (base_url and "11434" in base_url) or prefix in ("ollama", "ollama_chat") else "openai_compat"
        )
        return _resolve_local_heuristic(bare, runtime=runtime)

    if prefix == "groq" or "gpt-oss" in bare or bare.startswith("qwen/"):
        if "gpt-oss" in bare:
            return _GROQ_GPT_OSS_CAP
        if "qwen3" in bare or bare.startswith("qwen/qwen3"):
            return _DEEPSEEK_TOGGLE_CAP
        return _NO_THINKING

    if bare.startswith(("gpt-", "o1", "o3", "o4", "davinci", "babbage")):
        return _resolve_openai_capability(bare)
    if bare.startswith("claude"):
        return _resolve_anthropic_capability(bare)
    if bare.startswith("gemini"):
        return _resolve_gemini_capability(bare)
    if bare.startswith("deepseek"):
        if "reasoner" in bare or "r1" in bare:
            return _DEEPSEEK_ALWAYS_ON_CAP
        return _DEEPSEEK_TOGGLE_CAP
    if bare.startswith("magistral") or bare == "mistral-large-latest":
        return ThinkingCapability(
            mode="toggle",
            levels=("off", "on"),
            default_level="off",
            temp_when_off=0.0,
            temp_when_thinking=0.7,
        )
    if bare.startswith("kimi-k2") and "thinking" in bare:
        return _DEEPSEEK_TOGGLE_CAP
    if bare.startswith(
        (
            "llama-",
            "meta-llama/",
            "allam-",
            "canopylabs/",
            "moonshot-",
            "codestral-",
            "pixtral-",
            "ministral-",
            "devstral-",
            "mistral-",
        )
    ):
        return _NO_THINKING

    # Dynamic fallback for newly released or custom models via LiteLLM metadata.
    try:
        if litellm.supports_reasoning(model=model_name):
            return _OPENAI_O_SERIES_CAP
    except Exception as exc:
        logger.debug("litellm.supports_reasoning probe failed for %s: %s", model_name, exc)
    return _UNKNOWN_THINKING


def clamp_thinking_level(
    requested: str | None,
    capability: ThinkingCapability,
) -> tuple[str | None, str | None]:
    """Clamp ``requested`` to ``capability.levels``.

    Returns ``(effective_level, clamped_from)``. When ``requested`` is
    ``None`` or the model does not support reasoning, returns ``(None, None)``.
    """
    if not capability.supports_reasoning or not isinstance(requested, str):
        return None, None

    level = requested.strip().lower()
    if not level:
        return None, None

    if level in capability.levels:
        return level, None

    # Toggle-only models map any non-off level to "on".
    if capability.mode == "toggle":
        target = "off" if level == "off" and "off" in capability.levels else "on"
        if target in capability.levels:
            return target, level
        return capability.default_level, level

    # Multi-tier model receiving "on" -> default_level.
    if level == "on":
        return capability.default_level, level

    # Nearest supported level along the canonical scale.
    scale = ("off", "minimal", "low", "medium", "high", "max")
    if level not in scale:
        return capability.default_level, level

    req_idx = scale.index(level)
    best = min(
        capability.levels,
        key=lambda cand: (abs(scale.index(cand) - req_idx), scale.index(cand)),
    )
    return best, level


def _map_openai_effort(level: str, bare: str) -> str:
    if level == "off":
        return "none"
    if level == "max":
        return "xhigh" if bare.startswith("gpt-5") else "high"
    return level


def _translate_kwargs_for_capability(
    model_name: str,
    effective_level: str,
    capability: ThinkingCapability,
    base_url: str | None,
) -> tuple[dict[str, Any], int | None]:
    """Build provider-specific ``model_kwargs`` and optional ``max_tokens_min``."""
    prefix, bare = _strip_provider_prefix(model_name)

    if capability.mode == "effort":
        # Self-hosted OpenAI-compatible servers (llama.cpp, vLLM, LM Studio)
        if base_url and prefix not in ("ollama", "ollama_chat"):
            enable = effective_level != "off"
            extra_body: dict[str, Any] = {
                "chat_template_kwargs": {"enable_thinking": enable}
            }
            if capability.runtime == "llamacpp" and not enable:
                extra_body["reasoning_budget"] = 0
            return {
                "reasoning_effort": "none" if not enable else effective_level,
                "extra_body": extra_body,
            }, None
        return {"reasoning_effort": _map_openai_effort(effective_level, bare)}, None

    if capability.mode == "adaptive_effort":
        if effective_level == "off":
            return {"thinking": {"type": "disabled"}}, None
        return {
            "thinking": {"type": "adaptive"},
            "reasoning_effort": effective_level,
        }, None

    if capability.mode == "level":
        return {"reasoning_effort": effective_level}, None

    if capability.mode == "budget":
        if effective_level == "off":
            if bare.startswith("gemini-2.5"):
                return {"thinking": {"type": "enabled", "budget_tokens": 0}}, None
            return {"thinking": {"type": "disabled"}}, None
        budget = _BUDGET_TOKENS_BY_LEVEL.get(effective_level, 8192)
        max_floor = budget + 4096 if bare.startswith("claude") else None
        return {"thinking": {"type": "enabled", "budget_tokens": budget}}, max_floor

    if capability.mode == "toggle":
        is_on = effective_level != "off"
        if base_url and prefix not in ("ollama", "ollama_chat"):
            return {
                "reasoning_effort": "high" if is_on else "none",
                "extra_body": {"chat_template_kwargs": {"enable_thinking": is_on}},
            }, None
        return {"reasoning_effort": "high" if is_on else "none"}, None

    if capability.mode == "unknown":
        is_on = effective_level != "off"
        return (
            {"reasoning_effort": "none" if not is_on else effective_level},
            None,
        )

    return {}, None


def validate_thinking_level(
    model_name: str,
    thinking_level: str | None,
    capability: ThinkingCapability,
) -> str | None:
    """Strictly validate ``thinking_level`` against ``capability.levels``.

    Never silently overrides or downgrades the user's explicit choice:
    raises ``UnsupportedThinkingLevelError`` if ``thinking_level`` is
    incompatible with ``model_name``.
    """
    if not isinstance(thinking_level, str) or not thinking_level.strip():
        return None
    level = thinking_level.strip().lower()
    if capability.mode == "unknown":
        if level not in CANONICAL_LEVELS:
            raise UnsupportedThinkingLevelError(
                model_name=model_name,
                requested_level=level,
                supported_levels=CANONICAL_LEVELS,
            )
        return level
    if not capability.supports_reasoning or level not in capability.levels:
        raise UnsupportedThinkingLevelError(
            model_name=model_name,
            requested_level=level,
            supported_levels=capability.levels,
        )
    return level


def build_litellm_thinking_params(
    model_name: str,
    thinking_level: str | None,
    base_url: str | None = None,
    runtime_probe: LocalRuntimeProbe | None = None,
) -> ThinkingTranslation:
    """Translate a requested thinking level into LiteLLM kwargs & temperature.

    Raises ``UnsupportedThinkingLevelError`` if ``thinking_level`` is
    explicitly set to a value not supported by ``model_name``.
    """
    effective_probe = runtime_probe or get_cached_local_probe(base_url)
    capability = resolve_thinking_capability(
        model_name, base_url=base_url, runtime_probe=effective_probe
    )

    effective_level = validate_thinking_level(model_name, thinking_level, capability)
    if capability.mode == "none":
        return ThinkingTranslation(
            model_kwargs={},
            temperature=capability.temp_when_off,
            max_tokens_min=None,
            effective_level=None,
        )

    if effective_level is None:
        # Unset: respect provider default; keep safe temperature for always-on models.
        is_always_on = "off" not in capability.levels
        temp = capability.temp_when_thinking if is_always_on else capability.temp_when_off
        return ThinkingTranslation(
            model_kwargs={},
            temperature=temp,
            max_tokens_min=None,
            effective_level=None,
        )

    model_kwargs, max_tokens_min = _translate_kwargs_for_capability(
        model_name, effective_level, capability, base_url
    )
    is_thinking_active = effective_level != "off"
    temperature = (
        capability.temp_when_thinking if is_thinking_active else capability.temp_when_off
    )
    return ThinkingTranslation(
        model_kwargs=model_kwargs,
        temperature=temperature,
        max_tokens_min=max_tokens_min,
        effective_level=effective_level,
    )


def _origin_from_base_url(base_url: str) -> str:
    parsed = urlparse(base_url.strip())
    return f"{parsed.scheme}://{parsed.netloc}" if parsed.scheme and parsed.netloc else base_url.rstrip("/")


async def _probe_ollama(origin: str, models: list[str]) -> LocalRuntimeProbe | None:
    caps: dict[str, ThinkingCapability] = {}
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            tags_resp = await client.get(f"{origin}/api/tags")
            if tags_resp.status_code != 200:
                return None
            for model in models:
                show_resp = await client.post(
                    f"{origin}/api/show", json={"name": model}
                )
                if show_resp.status_code != 200:
                    caps[model] = _resolve_local_heuristic(model.lower(), runtime="ollama")
                    continue
                data = show_resp.json()
                model_caps = data.get("capabilities") or []
                if "thinking" in model_caps:
                    if "gpt-oss" in model.lower():
                        caps[model] = ThinkingCapability(
                            mode="effort",
                            levels=("low", "medium", "high"),
                            default_level="medium",
                            temp_when_off=None,
                            temp_when_thinking=None,
                            runtime="ollama",
                        )
                    else:
                        caps[model] = ThinkingCapability(
                            mode="toggle",
                            levels=("off", "on"),
                            default_level="on",
                            temp_when_off=0.0,
                            temp_when_thinking=0.6,
                            runtime="ollama",
                        )
                else:
                    caps[model] = ThinkingCapability(
                        mode="none",
                        levels=(),
                        default_level=None,
                        temp_when_off=0.0,
                        runtime="ollama",
                    )
        return LocalRuntimeProbe(runtime="ollama", model_capabilities=caps)
    except Exception:
        return None


async def _probe_llamacpp(origin: str, models: list[str]) -> LocalRuntimeProbe | None:
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            resp = await client.get(f"{origin}/props")
            if resp.status_code != 200:
                return None
            data = resp.json()
            if "chat_template_caps" not in data and "default_generation_settings" not in data:
                return None
            template_caps = data.get("chat_template_caps") or {}
            supports_effort = bool(template_caps.get("supports_reasoning_effort"))
            supports_think = bool(template_caps.get("supports_thinking"))
            caps: dict[str, ThinkingCapability] = {}
            for model in models:
                if supports_effort:
                    caps[model] = ThinkingCapability(
                        mode="effort",
                        levels=("off", "low", "medium", "high"),
                        default_level="medium",
                        temp_when_off=0.0,
                        temp_when_thinking=0.6,
                        runtime="llamacpp",
                    )
                elif supports_think:
                    caps[model] = ThinkingCapability(
                        mode="toggle",
                        levels=("off", "on"),
                        default_level="on",
                        temp_when_off=0.0,
                        temp_when_thinking=0.6,
                        runtime="llamacpp",
                    )
                else:
                    caps[model] = _resolve_local_heuristic(model.lower(), runtime="llamacpp")
            return LocalRuntimeProbe(runtime="llamacpp", model_capabilities=caps)
    except Exception:
        return None


async def probe_local_runtime(
    base_url: str,
    models: list[str],
    force_refresh: bool = False,
) -> LocalRuntimeProbe:
    """Detect a local LLM runtime and its per-model thinking capabilities."""
    origin = _origin_from_base_url(base_url)
    now = time.time()
    cached = _local_probe_cache.get(origin)
    if not force_refresh and cached and (now - cached[0]) < _LOCAL_PROBE_TTL_SECONDS:
        return cached[1]

    probe = await _probe_ollama(origin, models)
    if probe is None:
        probe = await _probe_llamacpp(origin, models)
    if probe is None:
        probe = LocalRuntimeProbe(
            runtime="openai_compat",
            model_capabilities={
                m: _resolve_local_heuristic(m.lower(), runtime="openai_compat")
                for m in models
            },
        )
    _local_probe_cache[origin] = (now, probe)
    return probe
