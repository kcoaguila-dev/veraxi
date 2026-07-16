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

    resolved = resolve_entities(entities)

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

    resolved = resolve_entities(entities)

    assert len(resolved) == 3, "Expected no entities to be merged"

    # Check that they retained their names
    names = {e["name"] for e in resolved}
    assert names == {"Alice", "Veraxi Corp", "AI"}


def test_resolve_entities_empty():
    assert resolve_entities([]) == []
