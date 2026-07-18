import json
import logging
from typing import List, Dict, Any, Tuple
from openai import OpenAI
from backend.config import get_config
from backend.prompts import EXTRACTION_PROMPT

logger = logging.getLogger(__name__)

# Fixed allowed schema
ALLOWED_ENTITY_TYPES = {"Person", "Organization", "Concept"}
ALLOWED_RELATION_TYPES = {
    ("Person", "Organization"): ["WORKS_AT", "FOUNDED"],
    ("Organization", "Concept"): ["DEVELOPS", "USES"],
    ("Concept", "Concept"): ["RELATES_TO"],
    ("Person", "Concept"): ["INVENTED", "RESEARCHES"],
}




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


def _is_valid_entity(ent_type: Any, name: Any) -> bool:
    return (
        ent_type in ALLOWED_ENTITY_TYPES
        and isinstance(name, str)
        and bool(name.strip())
    )


def _validate_single_relation(
    rel: Dict[str, str], entity_name_to_type: Dict[str, str]
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

    allowed_types = ALLOWED_RELATION_TYPES.get((from_type, to_type), [])
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
    entities: List[Dict[str, Any]],
) -> Tuple[List[Dict[str, Any]], Dict[str, str]]:
    valid_entities = []
    entity_name_to_type = {}

    for ent in entities:
        if not isinstance(ent, dict):
            continue

        ent_type = ent.get("type")
        name = ent.get("name")
        props = ent.get("properties", {})

        if _is_valid_entity(ent_type, name):
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
    relations: List[Dict[str, str]], entity_name_to_type: Dict[str, str]
) -> List[Dict[str, str]]:
    valid_relations = []
    for rel in relations:
        valid_rel = _validate_single_relation(rel, entity_name_to_type)
        if valid_rel:
            valid_relations.append(valid_rel)
    return valid_relations


def validate_extraction(
    entities: List[Dict[str, Any]], relations: List[Dict[str, str]]
) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """
    Pure-logic validation step that rejects/quarantines any LLM output that doesn't match the schema.
    """
    valid_entities, entity_name_to_type = _validate_entities(entities)
    valid_relations = _validate_relations(relations, entity_name_to_type)
    return valid_entities, valid_relations


def extract_entities_and_relations(
    text: str,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """
    Extract entities and relations using OpenAI API constrained to a fixed schema.
    """
    config = get_config()
    client_args = {}
    if config.llm_api_key:
        client_args["api_key"] = config.llm_api_key
    if config.llm_base_url:
        client_args["base_url"] = config.llm_base_url
        
    client = OpenAI(**client_args)

    try:
        response = client.chat.completions.create(
            model=config.llm_model_name,
            messages=[
                {"role": "system", "content": EXTRACTION_PROMPT},
                {"role": "user", "content": f"Text to analyze:\n{text}"}
            ],
            response_format={"type": "json_object"},
            temperature=0.0
        )

        output = _clean_llm_json_output(response.choices[0].message.content)
        data = json.loads(output)

        raw_entities = data.get("entities", [])
        raw_relations = data.get("relations", [])

        return validate_extraction(raw_entities, raw_relations)
    except Exception as e:
        logger.error(f"Failed to extract entities/relations: {e}")
        return [], []
