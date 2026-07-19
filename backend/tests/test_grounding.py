from unittest.mock import patch, MagicMock
from openai import OpenAIError
from backend.evaluation.grounding import evaluate_groundedness
import json

@patch("backend.evaluation.grounding.get_config")
@patch("backend.evaluation.grounding.OpenAI")
def test_grounding_success(mock_openai_class, mock_get_config):
    # Mock config
    mock_config = MagicMock()
    mock_config.llm_api_key = "fake_key"
    mock_config.llm_base_url = "http://fake_url"
    mock_config.llm_model_name = "fake-model"
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
def test_grounding_missing_credentials_fails_gracefully(mock_openai_class, mock_get_config):
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
    # Should short-circuit and return 1.0 (no false claims made)
    score = evaluate_groundedness("", "Context text")
    assert score == 1.0
