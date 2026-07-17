from backend.ingestion.entity_resolution import resolve_entities


def test_resolve_entities_deduplication():
    # Fake entity list with known duplicates
    entities = [
        {"type": "Organization", "name": "Veraxi Corp"},
        {
            "type": "Organization",
            "name": "Veraxi Corp",
            "properties": {"industry": "Tech"},
        },
        {
            "type": "Organization",
            "name": "Veraxi Corp",
            "properties": {"founded": "2023"},
        },
        {"type": "Person", "name": "Alice"},
    ]

    resolved, alias_mapping = resolve_entities(entities)

    # We expect Veraxi, Veraxi Corp, and veraxi corporation to be merged into one
    orgs = [e for e in resolved if e["type"] == "Organization"]
    assert (
        len(orgs) == 1
    ), "Expected the three organizations to be deduplicated into one"

    # The canonical name should be the longest one
    assert orgs[0]["name"] == "Veraxi Corp"

    # Properties should be merged
    props = orgs[0].get("properties", {})
    assert props.get("industry") == "Tech"
    assert props.get("founded") == "2023"


def test_resolve_entities_no_duplicates():
    # Fake entity list with no duplicates
    entities = [
        {"type": "Person", "name": "Alice", "properties": {"role": "Engineer"}},
        {
            "type": "Organization",
            "name": "Veraxi Corp",
            "properties": {"industry": "Tech"},
        },
        {"type": "Concept", "name": "AI"},
    ]

    resolved, alias_mapping = resolve_entities(entities)

    assert len(resolved) == 3, "Expected no entities to be merged"

    # Check that they retained their names
    names = {e["name"] for e in resolved}
    assert names == {"Alice", "Veraxi Corp", "AI"}


def test_resolve_entities_empty():
    resolved, alias_mapping = resolve_entities([])
    assert resolved == []
    assert alias_mapping == {}


def test_resolve_entities_rewrites_relations_with_aliases():
    """Test that relations referencing aliases are rewritten to canonical names."""
    # Entities with similar names that should be merged
    entities = [
        {"type": "Organization", "name": "Veraxi Corp"},
        {"type": "Organization", "name": "Veraxi Corporation"},  # Alias
        {"type": "Person", "name": "Alice"},
        {"type": "Concept", "name": "AI"},
    ]

    # Relations using the alias
    relations = [
        {"from_entity": "Alice", "to_entity": "Veraxi Corporation", "type": "WORKS_AT"},
        {"from_entity": "Veraxi Corp", "to_entity": "AI", "type": "DEVELOPS"},
    ]

    resolved_entities, alias_mapping = resolve_entities(entities)

    # Verify entities are merged - should have 3 entities (1 org, 1 person, 1 concept)
    assert len(resolved_entities) == 3

    # Get the canonical name (longest one)
    org_entities = [e for e in resolved_entities if e["type"] == "Organization"]
    assert len(org_entities) == 1
    canonical_name = org_entities[0]["name"]
    assert canonical_name == "Veraxi Corporation"  # Longest name becomes canonical

    # Verify alias mapping
    assert "Veraxi Corp" in alias_mapping
    assert "Veraxi Corporation" in alias_mapping
    assert alias_mapping["Veraxi Corp"] == canonical_name
    assert alias_mapping["Veraxi Corporation"] == canonical_name

    # Now rewrite relations using the alias mapping (mimicking __main__.py logic)
    rewritten_relations = []
    for rel in relations:
        from_entity = alias_mapping.get(rel["from_entity"], rel["from_entity"])
        to_entity = alias_mapping.get(rel["to_entity"], rel["to_entity"])
        rewritten_relations.append({
            "from_entity": from_entity,
            "to_entity": to_entity,
            "type": rel["type"]
        })

    # Verify both relations now use the canonical name
    assert len(rewritten_relations) == 2
    assert rewritten_relations[0]["from_entity"] == "Alice"
    assert rewritten_relations[0]["to_entity"] == canonical_name
    assert rewritten_relations[1]["from_entity"] == canonical_name
    assert rewritten_relations[1]["to_entity"] == "AI"
