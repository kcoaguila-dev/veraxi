import json
from unittest.mock import MagicMock, patch

from openai import OpenAIError

from backend.evaluation.grounding import evaluate_groundedness


@patch("backend.evaluation.grounding.get_config")
@patch("backend.evaluation.grounding.OpenAI")
def test_grounding_success(mock_openai_class, mock_get_config):
    # Mock config
    mock_config = MagicMock()
    mock_config.llm_api_key = "fake_key"
    mock_config.llm_base_url = "http://fake_url"
    mock_config.llm_model_name = "fake-model"
    mock_config.get_llm_client_args.return_value = {
        "api_key": "fake_key",
        "base_url": "http://fake_url",
    }
    mock_get_config.return_value = mock_config

    # Mock OpenAI client and response
    mock_client = MagicMock()
    mock_openai_class.return_value = mock_client

    mock_response = MagicMock()
    mock_choice = MagicMock()
    mock_choice.message.content = json.dumps({"score": 0.85, "reasoning": "Test"})
    mock_response.choices = [mock_choice]

    mock_client.chat.completions.create.return_value = mock_response

    score = evaluate_groundedness("Response text", "Context text")

    assert score == 0.85
    mock_client.chat.completions.create.assert_called_once()


@patch("backend.evaluation.grounding.get_config")
@patch("backend.evaluation.grounding.OpenAI")
def test_grounding_missing_credentials_fails_gracefully(
    mock_openai_class, mock_get_config
):
    # Mock OpenAI instantiation to throw missing credentials error
    mock_openai_class.side_effect = OpenAIError("Missing credentials")

    score = evaluate_groundedness("Response text", "Context text")

    # Should safely catch the error and return 0.0
    assert score == 0.0


def test_grounding_empty_context():
    # Should short-circuit and return 0.0
    score = evaluate_groundedness("Response text", "")
    assert score == 0.0


def test_grounding_empty_response():
    # Should short-circuit and return None
    score = evaluate_groundedness("", "Context text")
    assert score is None


def test_deterministic_grounding():
    # Full match
    context = "Antigravity is an agentic coding assistant designed by Google DeepMind."
    claim = "Antigravity was designed by Google DeepMind."
    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    assert score >= 0.8

    # Disjoint text
    disjoint_claim = "The moon is made of green cheese."
    disjoint_score = evaluate_groundedness(disjoint_claim, context, method="deterministic")
    assert disjoint_score == 0.0


def test_byok_protection_blocks_llm_without_key():
    import pytest

    with pytest.raises(ValueError, match="A user API key .* is required"):
        evaluate_groundedness(
            "Claim text",
            "Context text",
            method="llm",
            api_key=None,
            require_byok=True,
        )


def test_mcp_evaluate_grounding_defaults_to_free_deterministic():
    from backend.mcp_server.tools.evaluate_grounding import mcp_evaluate_grounding

    context = "Apple Inc. released the M4 Mac mini in November 2024."
    claim = "Apple released the M4 Mac mini."

    # Calls mcp_evaluate_grounding without API key -> should use deterministic and return score
    score = mcp_evaluate_grounding(claim, context)
    assert score is not None
    assert score >= 0.8

