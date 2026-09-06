import json
import logging
from typing import Any

import sentry_sdk
from backend.config import get_config
from backend.prompts import get_extraction_prompt
from openai import OpenAI

logger = logging.getLogger(__name__)




def _clean_llm_json_output(output: str) -> str:
    """Removes markdown code blocks if the LLM hallucinated them."""
    output = output.strip()
    if output.startswith("```json"):
        output = output[7:]
    elif output.startswith("```"):
        output = output[3:]

    output = output.removesuffix("```")

    return output.strip()


def _is_valid_entity(ent_type: Any, name: Any, allowed_entities: list[str]) -> bool:
    return (
        ent_type in allowed_entities
        and isinstance(name, str)
        and bool(name.strip())
    )


def _validate_single_relation(
    rel: dict[str, str], entity_name_to_type: dict[str, str], allowed_relations: dict
) -> dict[str, str] | None:
    if not isinstance(rel, dict):
        return None

    from_ent = rel.get("from_entity")
    to_ent = rel.get("to_entity")
    rel_type = rel.get("type")

    if from_ent not in entity_name_to_type or to_ent not in entity_name_to_type:
        return None

    from_type = entity_name_to_type[from_ent]
    to_type = entity_name_to_type[to_ent]

    allowed_types = allowed_relations.get(from_type, {}).get(to_type, [])
    if rel_type in allowed_types:
        return {"from_entity": from_ent, "to_entity": to_ent, "type": rel_type}
    return None


def _normalize_single_property(value: Any) -> Any | None:
    if value is None:
        return None
    if isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, list) and all(isinstance(item, (str, int, float, bool)) for item in value):
        return value
    return None

def _normalize_properties(props: Any) -> dict[str, Any]:
    """
    Normalize properties to Neo4j-safe values.
    Neo4j properties must be primitives or arrays of primitives - no nested maps.
    """
    if not isinstance(props, dict):
        return {}

    normalized = {}
    for key, value in props.items():
        norm_val = _normalize_single_property(value)
        if norm_val is not None:
            normalized[key] = norm_val

    return normalized


def _validate_entities(
    entities: list[dict[str, Any]], allowed_entities: list[str]
) -> tuple[list[dict[str, Any]], dict[str, str]]:
    valid_entities = []
    entity_name_to_type = {}

    for ent in entities:
        if not isinstance(ent, dict):
            continue

        ent_type = ent.get("type")
        name = ent.get("name")
        props = ent.get("properties", {})

        if _is_valid_entity(ent_type, name, allowed_entities):
            valid_entities.append(
                {
                    "type": ent_type,
                    "name": name,
                    "properties": _normalize_properties(props),
                }
            )
            entity_name_to_type[name] = ent_type

    return valid_entities, entity_name_to_type


def _validate_relations(
    relations: list[dict[str, str]], entity_name_to_type: dict[str, str], allowed_relations: dict
) -> list[dict[str, str]]:
    valid_relations = []
    for rel in relations:
        valid_rel = _validate_single_relation(rel, entity_name_to_type, allowed_relations)
        if valid_rel:
            valid_relations.append(valid_rel)
    return valid_relations


def validate_extraction(
    entities: list[dict[str, Any]], relations: list[dict[str, str]], schema: dict
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """
    Pure-logic validation step that rejects/quarantines any LLM output that doesn't match the schema.
    """
    if not schema:
        raise ValueError("A valid schema must be provided for validation.")
    valid_entities, entity_name_to_type = _validate_entities(entities, schema["entities"])
    valid_relations = _validate_relations(relations, entity_name_to_type, schema.get("relations", {}))
    return valid_entities, valid_relations


def extract_entities_and_relations(
    text: str, schema: dict, model_name: str | None = None
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """
    Extract entities and relations using OpenAI API constrained to a dynamic schema.
    """
    if not schema:
        raise ValueError("A valid schema must be provided for extraction.")
        
    config = get_config()
    client = OpenAI(**config.get_llm_client_args())

    try:
        response = client.chat.completions.create(
            model=model_name or config.llm_model_name,
            messages=[
                {"role": "system", "content": get_extraction_prompt(schema)},
                {"role": "user", "content": f"Text to analyze:\n{text}"}
            ],
            response_format={"type": "json_object"},
            temperature=0.0
        )

        output = _clean_llm_json_output(response.choices[0].message.content)
        data = json.loads(output)

        raw_entities = data.get("entities", [])
        raw_relations = data.get("relations", [])

        return validate_extraction(raw_entities, raw_relations, schema)
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        return [], []


def _extract_relations_from_sentence(sent, entity_name_to_type, allowed_relations):
    """
    Naively extract relations from a sentence based on entity co-occurrence.
    """
    relations = []
    ents_in_sent = [ent.text.strip() for ent in sent.ents if ent.text.strip() in entity_name_to_type]
    
    if len(ents_in_sent) >= 2:
        for i in range(len(ents_in_sent)):
            for j in range(i + 1, len(ents_in_sent)):
                e1 = ents_in_sent[i]
                e2 = ents_in_sent[j]
                if e1 == e2: continue
                
                t1 = entity_name_to_type.get(e1)
                t2 = entity_name_to_type.get(e2)
                
                allowed_t1_t2 = allowed_relations.get(t1, {}).get(t2, [])
                if allowed_t1_t2:
                    relations.append({"from_entity": e1, "to_entity": e2, "type": allowed_t1_t2[0]})
                
                allowed_t2_t1 = allowed_relations.get(t2, {}).get(t1, [])
                if allowed_t2_t1:
                    relations.append({"from_entity": e2, "to_entity": e1, "type": allowed_t2_t1[0]})
                    
    return relations


def extract_entities_and_relations_fast(
    text: str, schema: dict, language: str = "en", custom_stop_words: list | None = None
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """
    Extract entities and relations using spaCy (FastGraphRAG NLP fallback) instead of an LLM.
    This provides ~90/10 ratio extraction speeds, sacrificing deep reasoning for speed.
    """
    import logging

    import spacy
    
    model_map = {
        "en": "en_core_web_sm",
        "es": "es_core_news_sm",
        "fr": "fr_core_news_sm",
        "de": "de_core_news_sm",
    }
    model_name = model_map.get(language, "en_core_web_sm")
    
    try:
        nlp = spacy.load(model_name)
    except OSError:
        logging.info(f"Downloading spaCy model {model_name}...")  # noqa: LOG015
        import spacy.cli
        spacy.cli.download(model_name)
        nlp = spacy.load(model_name)

    # Add custom stop words
    if custom_stop_words:
        for word in custom_stop_words:
            nlp.Defaults.stop_words.add(word.lower())

    doc = nlp(text)
    
    entities = []
    entity_name_to_type = {}
    
    # SpaCy to Schema Type Mapping
    allowed_types = set(schema.get("entities", []))
    spacy_to_schema = {
        "PERSON": "Person",
        "ORG": "Organization",
        "GPE": "Location",
        "LOC": "Location",
        "FAC": "Location",
        "DATE": "Date",
        "EVENT": "Event",
        "WORK_OF_ART": "Concept"
    }

    # Extract Entities
    for ent in doc.ents:
        # Check if the root of the entity is a stop word
        if ent.root.is_stop or ent.text.lower() in nlp.Defaults.stop_words:
            continue
            
        name = ent.text.strip()
        if not name:
            continue
            
        # Try to map to the dynamic schema, otherwise use the spaCy label
        mapped_type = spacy_to_schema.get(ent.label_, ent.label_.capitalize())
        
        # If schema is strict, we should ideally coerce it. 
        # For fast NLP, we coerce to a generic 'Entity' if it doesn't match the schema, 
        # or just pass it through if it's close.
        if allowed_types and mapped_type not in allowed_types:
            # Fallback to the first allowed type, or generic "Entity"
            mapped_type = next(iter(allowed_types)) if allowed_types else "Entity"
            
        entities.append({
            "type": mapped_type,
            "name": name,
            "properties": {}
        })
        entity_name_to_type[name] = mapped_type

    # Extract Relationships based on sentence co-occurrence
    relations = []
    allowed_relations = schema.get("relations", {})
    
    for sent in doc.sents:
        relations.extend(_extract_relations_from_sentence(sent, entity_name_to_type, allowed_relations))
                
    # We still run it through validate_extraction to normalize it
    return validate_extraction(entities, relations, schema)
