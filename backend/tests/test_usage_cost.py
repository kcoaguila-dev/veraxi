"""Usage shaping, cost math and Deep estimate tests (Phase 5)."""

from types import SimpleNamespace

import pytest

from backend.mcp_server import formatter
from backend.mcp_server.formatter import (
    context_window_tokens_for_model,
    estimate_deep_usage,
    extract_usage_from_response,
    resolve_context_window_tokens,
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


class TestContextWindow:
    def test_known_model_resolves_window(self):
        # gpt-4o's 128k window is a stable entry in LiteLLM's bundled map.
        assert context_window_tokens_for_model("gpt-4o") == 128_000

    def test_provider_prefixed_model_resolves_window(self):
        assert context_window_tokens_for_model("openai/gpt-4o") == 128_000

    def test_unknown_model_window_is_null_not_invented(self):
        assert context_window_tokens_for_model("no-such-model-xyz") is None

    def test_missing_model_window_is_null(self):
        assert context_window_tokens_for_model(None) is None
        assert context_window_tokens_for_model("") is None

    def test_shape_usage_carries_window(self):
        shaped = shape_usage(
            {"prompt_tokens": 100, "completion_tokens": 5},
            model_name="gpt-4o",
        )
        assert shaped["context_window_tokens"] == 128_000

    def test_shape_usage_unknown_model_window_null(self):
        shaped = shape_usage(
            {"prompt_tokens": 100, "completion_tokens": 5},
            model_name="no-such-model-xyz",
        )
        assert shaped["context_window_tokens"] is None


class TestRuntimeContextWindow:
    """Runtime-reported windows outrank the catalog; failures fall back."""

    def setup_method(self):
        formatter.runtime_context_window_tokens.cache_clear()

    def teardown_method(self):
        formatter.runtime_context_window_tokens.cache_clear()

    def test_vllm_max_model_len_overrides_catalog(self, monkeypatch):
        monkeypatch.setattr(
            formatter,
            "_http_get_json",
            lambda url: {
                "data": [{"id": "gpt-4o", "max_model_len": 8192}],
            },
        )
        # Catalog says 128k for gpt-4o; the served cap (8192) must win.
        assert (
            resolve_context_window_tokens("gpt-4o", "http://localhost:8000/v1")
            == 8192
        )

    def test_llama_cpp_served_n_ctx_beats_trained(self, monkeypatch):
        monkeypatch.setattr(
            formatter,
            "_http_get_json",
            lambda url: {
                "data": [
                    {"id": "local-model", "meta": {"n_ctx": 4096, "n_ctx_train": 131072}}
                ],
            },
        )
        assert (
            resolve_context_window_tokens("local-model", "http://localhost:8080/v1")
            == 4096
        )

    def test_ollama_num_ctx_beats_trained_context_length(self, monkeypatch):
        monkeypatch.setattr(
            formatter,
            "_http_post_json",
            lambda url, payload: {
                "parameters": "temperature 0.7\nnum_ctx 32768",
                "model_info": {"llama.context_length": 131072},
            },
        )
        assert (
            resolve_context_window_tokens(
                "ollama/llama3.1", "http://localhost:11434"
            )
            == 32768
        )

    def test_ollama_context_length_when_no_num_ctx(self, monkeypatch):
        monkeypatch.setattr(
            formatter,
            "_http_post_json",
            lambda url, payload: {
                "model_info": {"qwen2.context_length": 32768},
            },
        )
        assert (
            resolve_context_window_tokens("qwen2", "http://localhost:11434/v1")
            == 32768
        )

    def test_runtime_failure_falls_back_to_catalog(self, monkeypatch):
        monkeypatch.setattr(formatter, "_http_get_json", lambda url: None)
        assert (
            resolve_context_window_tokens("gpt-4o", "http://localhost:8000/v1")
            == 128_000
        )

    def test_runtime_without_window_falls_back_to_catalog(self, monkeypatch):
        monkeypatch.setattr(
            formatter,
            "_http_get_json",
            lambda url: {"data": [{"id": "gpt-4o"}]},
        )
        assert (
            resolve_context_window_tokens("gpt-4o", "http://localhost:8000/v1")
            == 128_000
        )

    def test_unknown_model_and_no_runtime_window_is_none(self, monkeypatch):
        monkeypatch.setattr(formatter, "_http_get_json", lambda url: None)
        assert (
            resolve_context_window_tokens(
                "no-such-model-xyz", "http://localhost:8000/v1"
            )
            is None
        )

    def test_shape_usage_uses_runtime_window(self, monkeypatch):
        monkeypatch.setattr(
            formatter,
            "_http_get_json",
            lambda url: {"data": [{"id": "gpt-4o", "max_model_len": 16384}]},
        )
        shaped = shape_usage(
            {"prompt_tokens": 100, "completion_tokens": 5},
            model_name="gpt-4o",
            base_url="http://localhost:8000/v1",
        )
        assert shaped["context_window_tokens"] == 16384


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

    def test_context_window_flattened_into_metrics(self):
        finalized = formatter._finalize_metrics(
            {
                "generation_seconds": 1.0,
                "usage": shape_usage(
                    {"prompt_tokens": 10, "completion_tokens": 5},
                    model_name="gpt-4o",
                ),
            }
        )
        assert finalized["context_window_tokens"] == 128_000

    def test_absent_usage_flattens_to_nulls(self):
        finalized = formatter._finalize_metrics({"generation_seconds": 1.0, "usage": None})
        assert finalized["prompt_tokens"] is None
        assert finalized["total_tokens"] is None
        assert finalized["estimated_cost_usd"] is None
        assert finalized["context_window_tokens"] is None


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


class TestContextSegments:
    def _messages(self):
        from langchain_core.messages import (
            AIMessage,
            HumanMessage,
            SystemMessage,
            ToolMessage,
        )

        return [
            SystemMessage(content="You are a careful research assistant."),
            HumanMessage(content="What did the retrieval find about Qdrant?"),
            ToolMessage(
                content="Qdrant is a vector database written in Rust.",
                tool_call_id="call-1",
            ),
            AIMessage(content="It is a vector database."),
        ]

    def test_segments_split_by_message_type(self):
        from backend.mcp_server.formatter import count_context_segments

        segments = count_context_segments(self._messages(), None, "gpt-4o")
        assert segments is not None
        assert segments["system"] > 0
        assert segments["tool_results"] > 0
        assert segments["messages"] > 0
        assert segments["tools"] == 0

    def test_tools_segment_counts_bound_tool_schemas(self):
        from langchain_core.tools import tool

        @tool
        def search_docs(query: str) -> str:
            """Search the document corpus."""
            return query

        from backend.mcp_server.formatter import count_context_segments

        segments = count_context_segments(self._messages(), [search_docs], "gpt-4o")
        assert segments is not None
        assert segments["tools"] > 0

    def test_counting_failure_returns_none(self, monkeypatch):
        import litellm

        def boom(**kwargs):
            raise RuntimeError("no tokenizer")

        monkeypatch.setattr(litellm, "token_counter", boom)
        from backend.mcp_server.formatter import count_context_segments

        assert count_context_segments(self._messages(), None, "gpt-4o") is None

    def test_finalize_metrics_flattens_breakdown(self):
        from backend.mcp_server.formatter import _finalize_metrics

        finalized = _finalize_metrics(
            {
                "usage": None,
                "context_breakdown": {
                    "system": 10,
                    "tools": 20,
                    "tool_results": 30,
                    "messages": 40,
                },
            }
        )
        assert finalized["context_system_tokens"] == 10
        assert finalized["context_tools_tokens"] == 20
        assert finalized["context_tool_results_tokens"] == 30
        assert finalized["context_messages_tokens"] == 40
        assert "context_breakdown" not in finalized

    def test_finalize_metrics_without_breakdown_sets_none(self):
        from backend.mcp_server.formatter import _finalize_metrics

        finalized = _finalize_metrics({"usage": None})
        assert finalized["context_system_tokens"] is None
        assert finalized["context_messages_tokens"] is None
