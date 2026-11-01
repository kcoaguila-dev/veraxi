from backend.ingestion.entity_resolution import (
    entity_key,
    extract_in_text_aliases,
    normalize_name,
    resolve_entities,
    strip_generic_suffix,
)


def test_corporate_and_institutional_suffix_normalization():
    assert strip_generic_suffix(normalize_name("Apple Inc.")) == "apple"
    assert strip_generic_suffix(normalize_name("Apple Corporation")) == "apple"
    assert strip_generic_suffix(normalize_name("Acme Holdings LLC")) == "acme"
    assert (
        strip_generic_suffix(normalize_name("The Federal Reserve System"))
        == "federal reserve"
    )
    assert (
        strip_generic_suffix(normalize_name("Federal Reserve Board"))
        == "federal reserve"
    )

    assert entity_key("t1", "Org", "Apple Inc.") == entity_key("t1", "Org", "Apple")
    assert entity_key("t1", "Org", "The Federal Reserve System") == entity_key(
        "t1", "Org", "Federal Reserve"
    )


def test_in_text_parenthetical_alias_extraction_across_domains():
    text = (
        "The Federal Reserve (the Fed) hiked rates by 25 bps. "
        "Patients treated with acetaminophen (commonly called Tylenol) showed recovery. "
        "Taiwan Semiconductor Manufacturing Company (TSMC) expanded fab capacity."
    )
    alias_map = extract_in_text_aliases(text)

    assert "the fed" in {a.lower() for a in alias_map.get("federal reserve", set())}
    assert "tylenol" in {a.lower() for a in alias_map.get("acetaminophen", set())}
    assert "tsmc" in {
        a.lower() for a in alias_map.get("taiwan semiconductor manufacturing", set())
    }


def test_resolve_entities_multi_domain_via_aliases_and_acronyms():
    ents = [
        # Finance: linked via extracted aliases (no hardcoded dictionary needed)
        {
            "name": "Federal Reserve",
            "type": "Org",
            "aliases": ["The Fed", "US Central Bank"],
        },
        {"name": "The Fed", "type": "Org"},
        {"name": "US Central Bank", "type": "Org"},
        # Medicine / Oncology: linked via alias
        {"name": "Acetaminophen", "type": "Drug", "aliases": ["Tylenol"]},
        {"name": "Tylenol", "type": "Drug"},
        # Tech / Semiconductors: linked via acronym + suffix
        {"name": "Taiwan Semiconductor Manufacturing Company", "type": "Org"},
        {"name": "TSMC", "type": "Org"},
    ]
    resolved, mapping = resolve_entities(ents)

    assert len(resolved) == 3
    assert mapping["The Fed"] == mapping["Federal Reserve"]
    assert mapping["US Central Bank"] == mapping["Federal Reserve"]
    assert mapping["Tylenol"] == mapping["Acetaminophen"]
    assert mapping["TSMC"] == mapping["Taiwan Semiconductor Manufacturing Company"]


def test_llm_extraction_auto_attaches_parenthetical_aliases():
    from unittest.mock import MagicMock, patch
    from backend.ingestion.extract import extract_entities_and_relations

    mock_resp = MagicMock()
    mock_resp.choices = [
        MagicMock(
            message=MagicMock(
                content='{"entities": [{"type": "Org", "name": "Federal Reserve", "properties": {}}], "relations": []}'
            )
        )
    ]

    with patch("backend.ingestion.extract.OpenAI") as mock_openai:
        mock_openai.return_value.chat.completions.create.return_value = mock_resp
        entities, _ = extract_entities_and_relations(
            "The Federal Reserve (the Fed) announced a policy shift.",
            schema={"entities": ["Org"], "relations": {}},
        )
        assert len(entities) == 1
        assert "the Fed" in entities[0].get("aliases", [])
