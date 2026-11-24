from unittest.mock import AsyncMock, MagicMock, patch

import litellm
import pytest
from langchain_core.messages import AIMessage, HumanMessage

from backend.mcp_server.orchestrator import _create_chat_llm
from backend.thinking_policy import (
    LocalRuntimeProbe,
    ThinkingCapability,
    UnsupportedThinkingLevelError,
    build_litellm_thinking_params,
    clamp_thinking_level,
    resolve_thinking_capability,
)


@pytest.mark.parametrize(
    ("model", "level", "expected_kwargs", "expected_temp"),
    [
        ("gpt-5.4", "off", {"reasoning_effort": "none"}, 0.0),
        ("gpt-5.4", "minimal", {"reasoning_effort": "minimal"}, None),
        ("gpt-5.4", "high", {"reasoning_effort": "high"}, None),
        ("gpt-5.4", "max", {"reasoning_effort": "xhigh"}, None),
        ("o3-mini", "low", {"reasoning_effort": "low"}, None),
        ("o3-mini", "high", {"reasoning_effort": "high"}, None),
        ("gpt-4o", None, {}, 0.0),
        (
            "claude-sonnet-4-6",
            "high",
            {"thinking": {"type": "adaptive"}, "reasoning_effort": "high"},
            None,
        ),
        (
            "claude-sonnet-4-6",
            "off",
            {"thinking": {"type": "disabled"}},
            0.0,
        ),
        (
            "claude-3-7-sonnet-20250219",
            "medium",
            {"thinking": {"type": "enabled", "budget_tokens": 8192}},
            None,
        ),
        ("claude-3-5-sonnet-latest", None, {}, 0.0),
        ("gemini-3.6-flash", "minimal", {"reasoning_effort": "minimal"}, None),
        ("gemini-3.1-pro-preview", "low", {"reasoning_effort": "low"}, None),
        (
            "gemini-2.5-flash",
            "off",
            {"thinking": {"type": "enabled", "budget_tokens": 0}},
            0.0,
        ),
        (
            "gemini-2.5-pro",
            "high",
            {"thinking": {"type": "enabled", "budget_tokens": 24576}},
            None,
        ),
        ("deepseek-chat", "on", {"reasoning_effort": "high"}, 0.6),
        ("deepseek-chat", "off", {"reasoning_effort": "none"}, 0.0),
        ("deepseek-reasoner", "on", {"reasoning_effort": "high"}, None),
        ("openai/gpt-oss-20b", "medium", {"reasoning_effort": "medium"}, None),
        ("qwen/qwen3.6-27b", "off", {"reasoning_effort": "none"}, 0.0),
        ("llama-3.3-70b-versatile", None, {}, 0.0),
        ("moonshot-v1-auto", None, {}, 0.0),
    ],
)
def test_build_litellm_thinking_params_matrix(
    model, level, expected_kwargs, expected_temp
):
    res = build_litellm_thinking_params(model, level)
    assert res.model_kwargs == expected_kwargs
    assert res.temperature == expected_temp


@pytest.mark.parametrize(
    ("model", "invalid_level"),
    [
        ("gpt-4o", "high"),
        ("claude-3-5-sonnet-latest", "medium"),
        ("o3-mini", "off"),
        ("o3-mini", "max"),
        ("gemini-3.1-pro-preview", "off"),
        ("deepseek-reasoner", "off"),
        ("deepseek-chat", "high"),
        ("llama-3.3-70b-versatile", "low"),
    ],
)
def test_strict_fail_fast_raises_on_unsupported_thinking_level(model, invalid_level):
    with pytest.raises(UnsupportedThinkingLevelError):
        build_litellm_thinking_params(model, invalid_level)


def test_anthropic_budget_sets_max_tokens_floor():
    res = build_litellm_thinking_params("claude-3-7-sonnet-20250219", "high")
    assert res.model_kwargs == {"thinking": {"type": "enabled", "budget_tokens": 24576}}
    assert res.max_tokens_min == 24576 + 4096


def test_local_llamacpp_translation_includes_extra_body():
    probe = LocalRuntimeProbe(
        runtime="llamacpp",
        model_capabilities={
            "qwen3-8b": ThinkingCapability(
                mode="effort",
                levels=("off", "low", "medium", "high"),
                default_level="medium",
                temp_when_off=0.0,
                temp_when_thinking=0.6,
                runtime="llamacpp",
            )
        },
    )
    res_low = build_litellm_thinking_params(
        "qwen3-8b", "low", base_url="http://localhost:8080/v1", runtime_probe=probe
    )
    assert res_low.model_kwargs["reasoning_effort"] == "low"
    assert res_low.model_kwargs["extra_body"]["chat_template_kwargs"]["enable_thinking"] is True
    assert "reasoning_budget" not in res_low.model_kwargs["extra_body"]
    assert res_low.temperature == 0.6

    res_off = build_litellm_thinking_params(
        "qwen3-8b", "off", base_url="http://localhost:8080/v1", runtime_probe=probe
    )
    assert res_off.model_kwargs["reasoning_effort"] == "none"
    assert res_off.model_kwargs["extra_body"]["chat_template_kwargs"]["enable_thinking"] is False
    assert res_off.model_kwargs["extra_body"]["reasoning_budget"] == 0
    assert res_off.temperature == 0.0


def test_unknown_model_hides_ui_capability_but_passes_through_explicit_level():
    cap = resolve_thinking_capability("my-custom-unlisted-model")
    assert cap.mode == "unknown"
    assert cap.supports_reasoning is False
    assert cap.levels == ()

    res = build_litellm_thinking_params("my-custom-unlisted-model", "high")
    assert res.model_kwargs == {"reasoning_effort": "high"}


def test_clamp_thinking_level_toggle_and_bounds():
    toggle_cap = resolve_thinking_capability("deepseek-chat")
    assert clamp_thinking_level("high", toggle_cap) == ("on", "high")
    assert clamp_thinking_level("off", toggle_cap) == ("off", None)

    o_cap = resolve_thinking_capability("o3-mini")
    assert clamp_thinking_level("max", o_cap) == ("high", "max")
    assert clamp_thinking_level("off", o_cap) == ("low", "off")


def test_create_chat_llm_forwards_thinking_in_model_kwargs():
    with patch("backend.mcp_server.orchestrator.get_config") as mock_cfg:
        mock_cfg.return_value.llm_api_key = "k"
        mock_cfg.return_value.llm_base_url = None
        llm = _create_chat_llm("gpt-5.4", "k", thinking_level="high")
        assert llm.model_kwargs.get("reasoning_effort") == "high"
        assert llm.temperature is None


def test_create_chat_llm_anthropic_omits_temperature_when_thinking():
    with patch("backend.mcp_server.orchestrator.get_config") as mock_cfg:
        mock_cfg.return_value.llm_api_key = "k"
        mock_cfg.return_value.llm_base_url = None
        llm = _create_chat_llm("claude-sonnet-4-6", "k", thinking_level="medium")
        assert llm.model_kwargs["thinking"] == {"type": "adaptive"}
        assert llm.model_kwargs["reasoning_effort"] == "medium"
        assert llm.temperature is None


@pytest.mark.asyncio
async def test_runtime_unsupported_thinking_param_fails_fast_without_downgrade():
    from backend.mcp_server.orchestrator import _ainvoke_with_rate_limit_retry

    with patch("backend.mcp_server.orchestrator.get_config") as mock_cfg:
        mock_cfg.return_value.llm_api_key = "k"
        mock_cfg.return_value.llm_base_url = None
        llm = _create_chat_llm("gpt-5.4", "k", thinking_level="max")

    assert llm.model_kwargs.get("reasoning_effort") == "xhigh"
    err = litellm.exceptions.BadRequestError(
        message="Unsupported parameter: 'reasoning_effort' xhigh is not supported",
        model="gpt-5.4",
        llm_provider="openai",
    )
    mock_ainvoke = AsyncMock(side_effect=err)
    with (
        patch.object(type(llm), "ainvoke", mock_ainvoke),
        pytest.raises(litellm.exceptions.BadRequestError),
    ):
        await _ainvoke_with_rate_limit_retry(
            llm, [HumanMessage(content="hi")], "gpt-5.4"
        )
    assert mock_ainvoke.call_count == 1
    assert llm.model_kwargs.get("reasoning_effort") == "xhigh"
