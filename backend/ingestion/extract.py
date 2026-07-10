from typing import List, Dict, Any, Tuple

def extract_entities_and_relations(text: str) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """
    Extract entities and relations using dummy parsing for Phase 1.
    Entities: list of {type, name, properties}
    Relations: list of {from_entity, to_entity, type}
    """
    # Hardcoded response for Phase 1 testing based on the hardcoded text
    # expected to be passed from the orchestrator.
    # We will look for "Alice" and "Veraxi Corp" strings.

    entities = []
    relations = []

    if "Alice" in text:
        entities.append({
            "type": "Person",
            "name": "Alice",
            "properties": {"role": "Engineer"}
        })

    if "Veraxi Corp" in text:
        entities.append({
            "type": "Organization",
            "name": "Veraxi Corp",
            "properties": {"industry": "Tech"}
        })

    if "AI" in text:
        entities.append({
            "type": "Concept",
            "name": "AI",
            "properties": {"domain": "Computer Science"}
        })

    if "Alice" in text and "Veraxi Corp" in text:
        relations.append({
            "from_entity": "Alice",
            "to_entity": "Veraxi Corp",
            "type": "WORKS_AT"
        })

    if "Veraxi Corp" in text and "AI" in text:
        relations.append({
            "from_entity": "Veraxi Corp",
            "to_entity": "AI",
            "type": "DEVELOPS"
        })

    return entities, relations
