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


def test_deterministic_grounding_negation_awareness():
    context = "Companies improperly record restructuring charges to establish reserves and present them below the line."
    opposite_claim = "Companies do not improperly record restructuring charges to establish reserves."

    score = evaluate_groundedness(opposite_claim, context, method="deterministic")
    assert score is not None
    # Negation mismatch must be penalized
    assert score <= 0.3


def test_deterministic_grounding_numeric_awareness():
    context = "Apple reported Q3 2025 revenue of $94.9 billion, up 6% year over year."
    hallucinated_numbers_claim = "Apple reported Q3 2025 revenue of $500 trillion, down 90% year over year."

    score = evaluate_groundedness(hallucinated_numbers_claim, context, method="deterministic")
    assert score is not None
    # Mismatched metrics must be penalized
    assert score < 0.4


def test_fact_check_empty_context_fails():
    from backend.mcp_server.tools.fact_check import perform_fact_check

    with patch("backend.mcp_server.tools.fact_check.search_vectors", return_value=[]):
        res = perform_fact_check("Revenue increased year over year", min_score=0.5)
        assert res["passed"] is False
        assert res["score"] == 0.0
        assert "FACT CHECK FAILED" in res["markdown"]


def test_deterministic_grounding_comma_formatted_numbers():
    context = "The endowment fund holds $1,000,000 in liquid assets and $250,000 in bonds."
    claim = "The fund holds 1000000 dollars in liquid assets."

    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    assert score >= 0.75


def test_deterministic_grounding_citation_header_does_not_ground_claim_numbers():
    context = "[Document: Financial_Audit.pdf | Page: 42] Total revenue increased across all operating segments."
    hallucinated_claim = "Total revenue was 42 million."

    score = evaluate_groundedness(hallucinated_claim, context, method="deterministic")
    assert score is not None
    # 42 came from Page: 42, which must not validate a hallucinated 42 in the claim
    assert score < 0.4


def test_deterministic_grounding_multi_clause_negation_does_not_falsely_penalize():
    context = "The company records restructuring charges, and does not disclose them until Q4."
    grounded_affirmative_claim = "The company records restructuring charges."

    score = evaluate_groundedness(grounded_affirmative_claim, context, method="deterministic")
    assert score is not None
    # Negation in distant clause ('not disclose') must not falsely penalize 'records restructuring charges'
    assert score >= 0.75


def test_config_fail_fast_on_dimension_mismatch():
    import os
    import pytest
    from backend.config import Config

    orig_model = os.environ.get("EMBEDDING_MODEL_NAME")
    orig_dim = os.environ.get("EMBEDDING_DIMENSION")

    try:
        os.environ["EMBEDDING_MODEL_NAME"] = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
        os.environ["EMBEDDING_DIMENSION"] = "768"  # MiniLM is natively 384

        with pytest.raises(ValueError, match="Configuration mismatch: Model .* natively has dimension 384, but EMBEDDING_DIMENSION is configured as 768"):
            Config.from_env()
    finally:
        if orig_model is not None:
            os.environ["EMBEDDING_MODEL_NAME"] = orig_model
        else:
            os.environ.pop("EMBEDDING_MODEL_NAME", None)
        if orig_dim is not None:
            os.environ["EMBEDDING_DIMENSION"] = orig_dim
        else:
            os.environ.pop("EMBEDDING_DIMENSION", None)


def test_multilingual_stopwords_forensic_keeplist():
    from backend.evaluation.lexical import get_stopwords, MULTILINGUAL_NEGATIONS

    for lang in ("en", "de", "fr", "es", "ru"):
        stops = get_stopwords(language=lang, include_negations=False)
        assert len(stops) > 20
        # Negations must NEVER be in the stop word list
        assert not (stops & MULTILINGUAL_NEGATIONS), f"Negations leaked into stop words for {lang}"


def test_multilingual_grounding_negation_awareness():
    context = "Das Unternehmen erfasst Restrukturierungskosten und legt Rückstellungen an."
    opposite_claim = "Das Unternehmen erfasst keine Restrukturierungskosten."

    score = evaluate_groundedness(opposite_claim, context, method="deterministic")
    assert score is not None
    assert score <= 0.3


def test_multilingual_grounding_european_formatted_numbers():
    context = "Das verwaltete Vermögen beträgt 1.000.000 Euro und die Rendite liegt bei 5,5%."
    claim = "Das verwaltete Vermögen beträgt 1000000 Euro und die Rendite liegt bei 5.5%."

    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    assert score >= 0.75


def test_cjk_grounding_tokenization():
    context = "当社は2024年に利益を計上しました。"
    claim = "当社は2024年に利益を計上しました。"

    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    assert score == 1.0


def test_config_fail_fast_on_negative_or_zero_dimension():
    import os
    import pytest
    from backend.config import Config

    orig_dim = os.environ.get("EMBEDDING_DIMENSION")
    try:
        os.environ["EMBEDDING_DIMENSION"] = "0"
        with pytest.raises(ValueError, match="Invalid EMBEDDING_DIMENSION"):
            Config.from_env()

        os.environ["EMBEDDING_DIMENSION"] = "-1"
        with pytest.raises(ValueError, match="Invalid EMBEDDING_DIMENSION"):
            Config.from_env()
    finally:
        if orig_dim is not None:
            os.environ["EMBEDDING_DIMENSION"] = orig_dim
        else:
            os.environ.pop("EMBEDDING_DIMENSION", None)


def test_matryoshka_dimensions_wired_to_api_client():
    from unittest.mock import MagicMock, patch
    from backend.ingestion.chunk_embed import _DenseEmbeddingAdapter

    mock_cfg = MagicMock()
    mock_cfg.embedding_api_key = "test-key"
    mock_cfg.embedding_base_url = "https://api.openai.com/v1"
    mock_cfg.embedding_model_name = "text-embedding-3-small"
    mock_cfg.embedding_dimension = 512

    with patch("openai.OpenAI") as mock_openai_cls:
        mock_client = MagicMock()
        mock_item = MagicMock()
        mock_item.embedding = [0.1] * 512
        mock_client.embeddings.create.return_value = MagicMock(data=[mock_item])
        mock_openai_cls.return_value = mock_client

        adapter = _DenseEmbeddingAdapter(mock_cfg)
        assert adapter.is_matryoshka is True

        res = adapter.embed_passages(["test passage"])
        assert len(res) == 1
        assert len(res[0]) == 512
        mock_client.embeddings.create.assert_called_once_with(
            model="text-embedding-3-small",
            input=["test passage"],
            dimensions=512,
        )


def test_extract_fast_custom_stopwords_no_global_mutation():
    from backend.ingestion.extract import extract_entities_and_relations_fast, _load_spacy_model

    nlp = _load_spacy_model("en")
    initial_stops = set(nlp.Defaults.stop_words)

    unique_custom_stop = "xyzqwkcustomword123"
    assert unique_custom_stop not in initial_stops

    schema = {"entities": ["Person", "Organization"]}
    text = f"John Doe visited {unique_custom_stop} headquarters in Tokyo."

    entities, _ = extract_entities_and_relations_fast(
        text=text,
        schema=schema,
        language="en",
        custom_stop_words=[unique_custom_stop],
    )

    # Global spaCy class defaults must NOT have been mutated
    assert unique_custom_stop not in nlp.Defaults.stop_words
    # Verify entity with custom stop word was excluded
    extracted_names = [e["name"].lower() for e in entities]
    assert unique_custom_stop not in extracted_names


def test_multilingual_grounding_comparator_contradiction():
    # English: under vs over
    context_en = "The leverage ratio must remain under 3.0x according to the covenant."
    claim_en_opp = "The leverage ratio must remain over 3.0x according to the covenant."
    score_en = evaluate_groundedness(claim_en_opp, context_en, method="deterministic")
    assert score_en is not None
    assert score_en <= 0.3

    # German: unter vs über
    context_de = "Die Gesamtkosten liegen unter fünf Prozent des Kapitals."
    claim_de_opp = "Die Gesamtkosten liegen über fünf Prozent des Kapitals."
    score_de = evaluate_groundedness(claim_de_opp, context_de, method="deterministic")
    assert score_de is not None
    assert score_de <= 0.3


def test_scoped_comparator_contradiction_avoids_unrelated_clause_false_positive():
    # Context has "After" in an introductory clause, and "under 3.0x" for the covenant
    context = "After the corporate reorganization completed in March, the debt leverage ratio must remain under 3.0x."
    # Claim uses "Before" in a temporal clause, but correctly retains "under 3.0x"
    claim = "Before year-end, the debt leverage ratio must remain under 3.0x."
    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    # Must NOT be penalized by the 0.25 comparator contradiction cap
    assert score >= 0.65


def test_scoped_comparator_shared_noun_in_introductory_clause():
    # Context repeats the claim's subject noun ("debt") right after an opposing comparator ("After")
    context = "After the debt restructuring in March, the debt leverage ratio must remain under 3.0x."
    # Claim uses "Before" in a temporal clause, and "under 3.0x" for the covenant
    claim = "Before year-end, the debt leverage ratio must remain under 3.0x."
    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    # Must NOT trigger a false comparator contradiction penalty
    assert score >= 0.65



def test_normalize_numbers_3_decimal_and_european():
    from backend.evaluation.lexical import normalize_numbers

    # US 3-decimal fraction should NOT be converted to 0125
    assert normalize_numbers("The interest margin is 0.125% per annum.") == "The interest margin is 0.125% per annum."
    # US comma grouping with 3-decimal portion
    assert normalize_numbers("A total of 1,000.250 units") == "A total of 1000.250 units"
    # European thousands with decimal comma
    assert normalize_numbers("Der Betrag ist 1.000.000,50 Euro") == "Der Betrag ist 1000000.50 Euro"
    # Standalone European decimal comma
    assert normalize_numbers("Rendite von 5,5%") == "Rendite von 5.5%"


def test_cjk_grounding_paraphrase_preserves_single_character_tokens():
    # Context and Claim share key CJK characters and numbers
    context = "株式会社は2024年度の売上高を大幅に伸ばしました。"
    claim = "2024年度の売上高を伸ばしました。"
    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    assert score >= 0.75




def test_scoped_comparator_numeric_introductory_clause_no_false_positive():
    context = "After the debt restructuring in March, the debt leverage ratio must remain under 3.0x."
    claim = "Before 2026, the debt leverage ratio must remain under 3.0x."

    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    assert score >= 0.65


def test_scoped_comparator_coordinated_conjunction_clause():
    context = "The facility was amended after the debt review and the debt leverage ratio must remain under 3.0x."
    claim = "Before the audit and while the debt leverage ratio must remain under 3.0x."

    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    assert score >= 0.65


def test_extract_comparator_local_anchors_clause_bounded_fallback():
    from backend.evaluation.grounding import _extract_comparator_local_anchors

    sentence = "Before it can be processed, the payment arrives."
    comp = "before"
    meaningful_set = {"processed", "payment", "arrives"}
    claim_stems = {"process", "payment", "arriv"}

    # Window of 3 from "before" covers "it", "can", "be" (indices 1, 2, 3) - all stopwords.
    # The clause-bounded fallback should still find "processed" within target_clauses without leaking "payment"/"arrives".
    local_words, _local_stems = _extract_comparator_local_anchors(
        sentence, comp, meaningful_set, claim_stems, window=3
    )

    assert "processed" in local_words
    assert "payment" not in local_words
    assert "arrives" not in local_words


def test_scoped_comparator_contradiction_detected_with_stopword_distance():
    context = "After it can be processed, the invoice will be archived."
    claim = "Before it can be processed, the invoice will be archived."

    score = evaluate_groundedness(claim, context, method="deterministic")
    assert score is not None
    assert score <= 0.3
