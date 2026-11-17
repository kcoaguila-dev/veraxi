"""Usage shaping, cost math and Deep estimate tests (Phase 5)."""

from types import SimpleNamespace

import pytest

from backend.mcp_server import formatter
from backend.mcp_server.formatter import (
    estimate_deep_usage,
    extract_usage_from_response,
    shape_usage,
)

PRICING = {"priced-model": {"prompt": 2.0, "completion": 8.0}}


@pytest.fixture()
def priced(monkeypatch):
    monkeypatch.setattr(
        "backend.models_config.MODEL_PRICING_USD_PER_1M_TOKENS", PRICING
    )


class TestShapeUsage:
    def test_with_pricing_cost_math(self, priced):
        shaped = shape_usage(
            {"prompt_tokens": 1_000_000, "completion_tokens": 500_000, "total_tokens": 1_500_000},
            model_name="priced-model",
        )
        assert shaped["prompt_tokens"] == 1_000_000
        assert shaped["completion_tokens"] == 500_000
        assert shaped["total_tokens"] == 1_500_000
        # 1M * $2/1M + 0.5M * $8/1M = $6.00
        assert shaped["estimated_cost_usd"] == pytest.approx(6.0)

    def test_pricing_matches_with_provider_prefix(self, priced):
        shaped = shape_usage(
            {"prompt_tokens": 100, "completion_tokens": 100},
            model_name="openai/priced-model",
        )
        assert shaped["estimated_cost_usd"] is not None

    def test_without_pricing_cost_is_null_tokens_present(self):
        shaped = shape_usage(
            {"prompt_tokens": 120, "completion_tokens": 30},
            model_name="unpriced-model",
        )
        assert shaped["prompt_tokens"] == 120
        assert shaped["completion_tokens"] == 30
        assert shaped["total_tokens"] == 150  # derived sum when total absent
        assert shaped["estimated_cost_usd"] is None

    def test_langchain_spelling(self):
        shaped = shape_usage({"input_tokens": 10, "output_tokens": 5, "total_tokens": 15})
        assert shaped["prompt_tokens"] == 10
        assert shaped["completion_tokens"] == 5
        assert shaped["total_tokens"] == 15

    def test_absent_usage_is_null(self):
        assert shape_usage(None) is None
        assert shape_usage({}) is None
        assert shape_usage({"unrelated": 1}) is None
        assert shape_usage("tokens") is None


class TestExtractUsage:
    def test_usage_metadata(self):
        response = SimpleNamespace(
            usage_metadata={"input_tokens": 7, "output_tokens": 3, "total_tokens": 10},
            response_metadata={},
        )
        assert extract_usage_from_response(response)["total_tokens"] == 10

    def test_response_metadata_token_usage(self):
        response = SimpleNamespace(
            usage_metadata=None,
            response_metadata={"token_usage": {"prompt_tokens": 4, "completion_tokens": 2}},
        )
        assert extract_usage_from_response(response)["prompt_tokens"] == 4

    def test_no_usage_anywhere(self):
        response = SimpleNamespace(usage_metadata=None, response_metadata={})
        assert extract_usage_from_response(response) is None
        assert extract_usage_from_response(object()) is None


class TestFinalizeMetricsUsage:
    def test_usage_flattened_into_metrics(self, priced):
        finalized = formatter._finalize_metrics(
            {
                "generation_seconds": 1.0,
                "usage": shape_usage(
                    {"prompt_tokens": 10, "completion_tokens": 5},
                    model_name="priced-model",
                ),
            }
        )
        assert finalized["prompt_tokens"] == 10
        assert finalized["completion_tokens"] == 5
        assert finalized["total_tokens"] == 15
        assert finalized["estimated_cost_usd"] is not None
        assert "usage" not in finalized

    def test_absent_usage_flattens_to_nulls(self):
        finalized = formatter._finalize_metrics({"generation_seconds": 1.0, "usage": None})
        assert finalized["prompt_tokens"] is None
        assert finalized["total_tokens"] is None
        assert finalized["estimated_cost_usd"] is None


class TestDeepEstimate:
    def test_range_derived_from_configured_limits(self):
        from backend.mcp_server.orchestrator_multi_agent import (
            DEBATE_LLM_CALLS_PER_ROUND,
            DEBATE_MAX_ITERATIONS,
        )

        estimate = estimate_deep_usage()
        assert estimate["max_rounds"] == DEBATE_MAX_ITERATIONS
        assert estimate["llm_calls"]["min"] == DEBATE_LLM_CALLS_PER_ROUND + 1
        assert (
            estimate["llm_calls"]["max"]
            == DEBATE_LLM_CALLS_PER_ROUND * DEBATE_MAX_ITERATIONS + 1
        )
        assert estimate["total_tokens"]["min"] < estimate["total_tokens"]["max"]
        assert estimate["is_estimate"] is True
        assert estimate["estimated_cost_usd"] is None  # unpriced by default

    def test_estimate_cost_when_priced(self, priced):
        estimate = estimate_deep_usage(model_name="priced-model")
        cost = estimate["estimated_cost_usd"]
        assert cost is not None
        assert 0 < cost["min"] < cost["max"]
