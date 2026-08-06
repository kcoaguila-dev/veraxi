import json
import sentry_sdk
import logging
from typing import List, Dict, Any, Tuple
from openai import OpenAI
from backend.config import get_config
from backend.prompts import get_extraction_prompt

logger = logging.getLogger(__name__)




def _clean_llm_json_output(output: str) -> str:
    """Removes markdown code blocks if the LLM hallucinated them."""
    output = output.strip()
    if output.startswith("```json"):
        output = output[7:]
    elif output.startswith("```"):
        output = output[3:]

    if output.endswith("```"):
        output = output[:-3]

    return output.strip()


def _is_valid_entity(ent_type: Any, name: Any, allowed_entities: list[str]) -> bool:
    return (
        ent_type in allowed_entities
        and isinstance(name, str)
        and bool(name.strip())
    )


def _validate_single_relation(
    rel: Dict[str, str], entity_name_to_type: Dict[str, str], allowed_relations: dict
) -> Dict[str, str] | None:
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

def _normalize_properties(props: Any) -> Dict[str, Any]:
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
    entities: List[Dict[str, Any]], allowed_entities: list[str]
) -> Tuple[List[Dict[str, Any]], Dict[str, str]]:
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
    relations: List[Dict[str, str]], entity_name_to_type: Dict[str, str], allowed_relations: dict
) -> List[Dict[str, str]]:
    valid_relations = []
    for rel in relations:
        valid_rel = _validate_single_relation(rel, entity_name_to_type, allowed_relations)
        if valid_rel:
            valid_relations.append(valid_rel)
    return valid_relations


def validate_extraction(
    entities: List[Dict[str, Any]], relations: List[Dict[str, str]], schema: dict
) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """
    Pure-logic validation step that rejects/quarantines any LLM output that doesn't match the schema.
    """
    if not schema:
        raise ValueError("A valid schema must be provided for validation.")
    valid_entities, entity_name_to_type = _validate_entities(entities, schema["entities"])
    valid_relations = _validate_relations(relations, entity_name_to_type, schema.get("relations", {}))
    return valid_entities, valid_relations


def extract_entities_and_relations(
    text: str, schema: dict
) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """
    Extract entities and relations using OpenAI API constrained to a dynamic schema.
    """
    if not schema:
        raise ValueError("A valid schema must be provided for extraction.")
        
    config = get_config()
    client = OpenAI(**config.get_llm_client_args())

    try:
        response = client.chat.completions.create(
            model=config.llm_model_name,
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
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Failed to extract entities/relations: {e}")
        return [], []


def extract_entities_and_relations_fast(
    text: str, schema: dict, language: str = "en", custom_stop_words: list = None
) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """
    Extract entities and relations using spaCy (FastGraphRAG NLP fallback) instead of an LLM.
    This provides ~90/10 ratio extraction speeds, sacrificing deep reasoning for speed.
    """
    import spacy
    import logging
    
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
        logging.info(f"Downloading spaCy model {model_name}...")
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
            mapped_type = list(allowed_types)[0] if allowed_types else "Entity"
            
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
        sent_ents = [ent.text.strip() for ent in sent.ents if ent.text.strip()]
        # Remove duplicates
        sent_ents = list(set(sent_ents))
        
        # Link every entity to every other entity in the same sentence
        for i in range(len(sent_ents)):
            for j in range(i + 1, len(sent_ents)):
                from_ent = sent_ents[i]
                to_ent = sent_ents[j]
                
                from_type = entity_name_to_type.get(from_ent)
                to_type = entity_name_to_type.get(to_ent)
                
                # Check if there is a specific allowed relation for these types
                rel_type = "RELATED_TO"
                if from_type and to_type:
                    valid_rels = allowed_relations.get(from_type, {}).get(to_type, [])
                    if valid_rels:
                        rel_type = valid_rels[0]
                        
                relations.append({
                    "from_entity": from_ent,
                    "to_entity": to_ent,
                    "type": rel_type
                })
                
    # We still run it through validate_extraction to normalize it
    return validate_extraction(entities, relations, schema)
