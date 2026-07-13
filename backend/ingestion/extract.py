import json
import logging
from typing import List, Dict, Any, Tuple
from anthropic import Anthropic
from backend.config import get_config

logger = logging.getLogger(__name__)

# Fixed allowed schema
ALLOWED_ENTITY_TYPES = {"Person", "Organization", "Concept"}
ALLOWED_RELATION_TYPES = {
    ("Person", "Organization"): ["WORKS_AT", "FOUNDED"],
    ("Organization", "Concept"): ["DEVELOPS", "USES"],
    ("Concept", "Concept"): ["RELATES_TO"],
    ("Person", "Concept"): ["INVENTED", "RESEARCHES"]
}

EXTRACTION_PROMPT = """
You are a precise data extraction tool. Extract entities and relationships from the following text.
Strictly adhere to this JSON format and schema:

{
  "entities": [
    {
      "type": "Person|Organization|Concept",
      "name": "string",
      "properties": {"key": "value"}
    }
  ],
  "relations": [
    {
      "from_entity": "string (must match an entity name)",
      "to_entity": "string (must match an entity name)",
      "type": "string"
    }
  ]
}

Allowed Entity Types: Person, Organization, Concept
Allowed Relation Types:
- Person to Organization: WORKS_AT, FOUNDED
- Organization to Concept: DEVELOPS, USES
- Concept to Concept: RELATES_TO
- Person to Concept: INVENTED, RESEARCHES

Only output valid JSON. No markdown formatting, no explanations.
"""

def extract_entities_and_relations(text: str) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """
    Extract entities and relations using Anthropic API constrained to a fixed schema.
    """
    config = get_config()
    client = Anthropic(api_key=config.anthropic_api_key)

    try:
        response = client.messages.create(
            model="claude-3-haiku-20240307",
            max_tokens=1000,
            system=EXTRACTION_PROMPT,
            messages=[
                {"role": "user", "content": text}
            ],
            temperature=0.0
        )
        output = response.content[0].text

        # Clean markdown code blocks if the LLM adds them
        output = output.strip()
        if output.startswith("```json"):
            output = output[7:]
        elif output.startswith("```"):
            output = output[3:]

        if output.endswith("```"):
            output = output[:-3]

        output = output.strip()

        data = json.loads(output)

        raw_entities = data.get("entities", [])
        raw_relations = data.get("relations", [])

        return validate_extraction(raw_entities, raw_relations)
    except Exception as e:
        logger.error(f"Failed to extract entities/relations: {e}")
        return [], []

def validate_extraction(entities: List[Dict[str, Any]], relations: List[Dict[str, str]]) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """
    Pure-logic validation step that rejects/quarantines any LLM output that doesn't match the schema.
    """
    valid_entities = []
    entity_name_to_type = {}

    # Validate entities
    for ent in entities:
        if not isinstance(ent, dict):
            continue

        ent_type = ent.get("type")
        name = ent.get("name")
        props = ent.get("properties", {})

        if ent_type in ALLOWED_ENTITY_TYPES and isinstance(name, str) and name.strip():
            valid_entities.append({
                "type": ent_type,
                "name": name,
                "properties": props if isinstance(props, dict) else {}
            })
            entity_name_to_type[name] = ent_type

    valid_relations = []

    # Validate relations
    for rel in relations:
        if not isinstance(rel, dict):
            continue

        from_ent = rel.get("from_entity")
        to_ent = rel.get("to_entity")
        rel_type = rel.get("type")

        if from_ent in entity_name_to_type and to_ent in entity_name_to_type:
            from_type = entity_name_to_type[from_ent]
            to_type = entity_name_to_type[to_ent]

            allowed_types = ALLOWED_RELATION_TYPES.get((from_type, to_type), [])
            if rel_type in allowed_types:
                valid_relations.append({
                    "from_entity": from_ent,
                    "to_entity": to_ent,
                    "type": rel_type
                })

    return valid_entities, valid_relations
