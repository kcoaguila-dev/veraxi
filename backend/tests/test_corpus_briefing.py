"""Tests for the Corpus Briefing (Phase 6a).

The briefing runs against an in-memory fake implementing the
BriefingGraphClient protocol — no Neo4j, no network, no LLM. The
Neo4j adapter is exercised with a recording stub to prove its Cypher
stays parameterized, and to prove community detection is delegated
to the existing graph_analytics implementation.
"""

import asyncio

from backend.retrieval.corpus_briefing import (
    FUNCTIONAL_RELATIONS,
    Neo4jBriefingClient,
    build_briefing,
    render_briefing_markdown,
)


class FakeBriefingClient:
    """In-memory BriefingGraphClient over fixture rows."""

    def __init__(self, *, communities=None, counts=None, degrees=None,
                 newest=None, functional_rows=None):
        self._communities = communities or []
        self._counts = counts or {"nodes_by_label": {}, "relationships_by_type": {}}
        self._degrees = degrees or {}
        self._newest = newest or []
        self._functional_rows = functional_rows or []

    def communities(self, tenant_id, min_community_size=1):
        return [c for c in self._communities if c["size"] >= min_community_size]

    def corpus_counts(self, tenant_id):
        return self._counts

    def entity_degrees(self, tenant_id, names):
        return [self._degrees[name] for name in names if name in self._degrees]

    def newest_entities(self, tenant_id, limit=10):
        return self._newest[:limit]

    def functional_relation_rows(self, tenant_id, relation_types):
        assert set(relation_types) == set(FUNCTIONAL_RELATIONS)
        return self._functional_rows


def _fixture_client() -> FakeBriefingClient:
    return FakeBriefingClient(
        communities=[
            {"community": "2", "size": 2, "members": ["Carol", "Dave"]},
            {"community": "1", "size": 3, "members": ["Alice", "Bob", "Acme"]},
        ],
        counts={
            "nodes_by_label": {"Person": 4, "Organization": 1},
            "relationships_by_type": {"WORKS_AT": 2, "BORN_IN": 3},
        },
        degrees={
            "Alice": {"name": "Alice", "type": "Person", "degree": 5},
            "Bob": {"name": "Bob", "type": "Person", "degree": 2},
            "Acme": {"name": "Acme", "type": "Organization", "degree": 4},
            "Carol": {"name": "Carol", "type": "Person", "degree": 1},
            "Dave": {"name": "Dave", "type": "Person", "degree": 3},
        },
        newest=[
            {"name": "Dave", "type": "Person", "first_seen": "2026-11-10T00:00:00Z"},
            {"name": "Carol", "type": "Person", "first_seen": "2026-11-01T00:00:00Z"},
        ],
        functional_rows=[
            {"entity": "Alice", "relation": "BORN_IN", "targets": ["Paris", "London"]},
            {"entity": "Bob", "relation": "BORN_IN", "targets": ["Berlin"]},
        ],
    )


def test_communities_ranked_by_size_with_top_entities_by_degree():
    briefing = build_briefing("t", client=_fixture_client())
    assert briefing["tenant"] == "t"
    assert briefing["generated_from"]["total_nodes"] == 5
    assert briefing["generated_from"]["total_relationships"] == 5
    communities = briefing["top_communities"]
    assert [c["id"] for c in communities] == ["1", "2"]
    assert communities[0]["size"] == 3
    top = communities[0]["top_entities"]
    assert [e["name"] for e in top] == ["Alice", "Acme", "Bob"]
    assert top[0]["degree"] == 5


def test_contradiction_rule_fires_on_multiple_functional_targets():
    briefing = build_briefing("t", client=_fixture_client())
    flags = briefing["contradiction_flags"]
    assert flags == [
        {"entity": "Alice", "relation": "BORN_IN", "targets": ["London", "Paris"]}
    ]


def test_contradiction_rule_does_not_fire_on_consistent_fixture():
    client = FakeBriefingClient(
        functional_rows=[
            {"entity": "Bob", "relation": "BORN_IN", "targets": ["Berlin"]},
            {"entity": "Acme", "relation": "HEADQUARTERED_IN", "targets": ["Tokyo"]},
        ]
    )
    briefing = build_briefing("t", client=client)
    assert briefing["contradiction_flags"] == []


def test_newest_entities_pass_through_with_first_seen_proxy():
    briefing = build_briefing("t", client=_fixture_client())
    assert briefing["newest_entities"][0]["name"] == "Dave"
    assert briefing["newest_entities"][0]["first_seen"] == "2026-11-10T00:00:00Z"


def test_empty_corpus_yields_valid_empty_briefing():
    briefing = build_briefing("empty", client=FakeBriefingClient())
    assert briefing["generated_from"]["total_nodes"] == 0
    assert briefing["generated_from"]["total_relationships"] == 0
    assert briefing["top_communities"] == []
    assert briefing["newest_entities"] == []
    assert briefing["contradiction_flags"] == []
    markdown = render_briefing_markdown(briefing)
    assert "Corpus Briefing" in markdown


def test_markdown_renders_all_sections():
    markdown = render_briefing_markdown(build_briefing("t", client=_fixture_client()))
    assert "## Overview" in markdown
    assert "## Top Communities" in markdown
    assert "## Newest Entities" in markdown
    assert "## Contradiction Flags" in markdown
    assert "Alice" in markdown
    assert "BORN_IN" in markdown


# ---------------------------------------------------------------------------
# MCP tool wrapper + registration
# ---------------------------------------------------------------------------


def test_mcp_tool_returns_briefing_and_markdown_on_request():
    from backend.mcp_server.tools.corpus_tools import corpus_briefing, tool_schemas

    assert {d["function"]["name"] for d in tool_schemas()} == {"corpus_briefing"}
    result = corpus_briefing(tenant_id="t", client=_fixture_client())
    assert "markdown" not in result
    assert result["top_communities"][0]["id"] == "1"
    with_md = corpus_briefing(
        tenant_id="t", include_markdown=True, client=_fixture_client()
    )
    assert "## Top Communities" in with_md["markdown"]


def test_tool_registered_in_dispatch_and_mcp_server(monkeypatch):
    from backend.mcp_server.handlers.tool_registry import TOOL_HANDLERS
    from backend.mcp_server.handlers.tool_schemas import REGISTERED_TOOLS
    from backend.mcp_server.tool_dispatch import get_tools

    names = {tool.name for tool in REGISTERED_TOOLS}
    assert "mcp_corpus_briefing" in names
    assert "mcp_corpus_briefing" in TOOL_HANDLERS

    tools = asyncio.run(get_tools({"file_search_enabled": True}, tenant_id="t"))
    assert "corpus_briefing" in {t["function"]["name"] for t in tools}


def test_dispatch_execute_single_tool(monkeypatch):
    import backend.mcp_server.tools.corpus_tools as corpus_tools_module
    from backend.mcp_server.tool_dispatch import _execute_single_tool

    original = corpus_tools_module.corpus_briefing
    monkeypatch.setattr(
        corpus_tools_module,
        "corpus_briefing",
        lambda tenant_id="default", include_markdown=False, client=None: original(
            tenant_id=tenant_id, include_markdown=include_markdown,
            client=_fixture_client(),
        ),
    )
    hits, graph_hits = _execute_single_tool(
        "corpus_briefing", {}, "t", {"file_search_enabled": True}
    )
    assert graph_hits == []
    assert hits[0].payload["tenant"] == "t"
    assert hits[0].sources == ["Corpus Briefing"]

    hits, graph_hits = _execute_single_tool(
        "corpus_briefing", {}, "t", {"file_search_enabled": False}
    )
    assert hits == [] and graph_hits == []


# ---------------------------------------------------------------------------
# Neo4j adapter: parameterized Cypher + community reuse
# ---------------------------------------------------------------------------


class RecordingNeo4jStub:
    def __init__(self):
        self.calls = []

    def execute_read(self, query, parameters=None):
        self.calls.append((query, parameters or {}))
        return []


def test_neo4j_adapter_parameterized():
    stub = RecordingNeo4jStub()
    client = Neo4jBriefingClient(stub)
    client.corpus_counts("tenant-a")
    client.entity_degrees("tenant-a", ["Alice"])
    client.newest_entities("tenant-a", limit=5)
    client.functional_relation_rows("tenant-a", list(FUNCTIONAL_RELATIONS))

    assert len(stub.calls) == 5  # corpus_counts issues two reads
    for query, params in stub.calls:
        assert "tenant-a" not in query
        assert "Alice" not in query
        assert params["tenant_id"] == "tenant-a"
    assert stub.calls[-1][1]["relation_types"] == list(FUNCTIONAL_RELATIONS)


def test_neo4j_adapter_communities_reuse_graph_analytics(monkeypatch):
    from backend.retrieval import graph_analytics

    calls = {}

    def fake_detection(client, min_community_size=1, tenant_id="default"):
        calls["tenant_id"] = tenant_id
        calls["min"] = min_community_size
        return [{"community": "9", "size": 1, "members": ["Solo"]}]

    monkeypatch.setattr(
        graph_analytics, "get_community_detection", fake_detection
    )
    client = Neo4jBriefingClient(RecordingNeo4jStub())
    rows = client.communities("tenant-a", min_community_size=2)
    assert rows[0]["community"] == "9"
    assert calls == {"tenant_id": "tenant-a", "min": 2}


def test_top_communities_exclude_unlinked_chunks_and_degree_zero():
    client = FakeBriefingClient(
        communities=[
            {"community": "1", "size": 3, "members": ["Alice", "UnlinkedChunk_ab12", "Ghost"]},
            {"community": "2", "size": 1, "members": ["UnlinkedChunk_cd34"]},
        ],
        counts={"nodes_by_label": {"Person": 2, "Chunk": 2}, "relationships_by_type": {}},
        degrees={
            "Alice": {"name": "Alice", "type": "Person", "degree": 4},
            "UnlinkedChunk_ab12": {"name": "UnlinkedChunk_ab12", "type": "Chunk", "degree": 0},
            "Ghost": {"name": "Ghost", "type": "Person", "degree": 0},
        },
    )
    briefing = build_briefing("t", client=client)
    communities = briefing["top_communities"]
    assert [c["id"] for c in communities] == ["1"]
    top_names = [e["name"] for e in communities[0]["top_entities"]]
    assert top_names == ["Alice"]
