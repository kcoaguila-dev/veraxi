"""Route tests for /api/v1/corpus/* and /api/v1/dbt/*.

The graph layer is faked by monkeypatching the functions the routes
module imported, following test_memory_routes.py's harness pattern.
"""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.routes import corpus_insights as routes

FAKE_BRIEFING = {
    "tenant": "tenant-1",
    "generated_from": {
        "total_nodes": 12,
        "total_relationships": 9,
        "nodes_by_label": {"Entity": 12},
        "relationships_by_type": {"RELATED_TO": 9},
        "community_count": 1,
    },
    "top_communities": [
        {"id": 0, "size": 3, "top_entities": [{"name": "Acme", "type": "Org", "degree": 4}]}
    ],
    "newest_entities": [{"name": "Acme", "type": "Org", "first_seen": "2026-01-01"}],
    "contradiction_flags": [],
    "contradiction_rule": "heuristic",
}


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setattr(routes, "build_briefing", lambda tenant_id: FAKE_BRIEFING)
    app = FastAPI()
    routes.register_corpus_insights_routes(app, lambda: "tenant-1", lambda: None, None)
    return TestClient(app, raise_server_exceptions=False)


class TestBriefingRoute:
    def test_briefing_returns_json_and_markdown(self, client):
        resp = client.get("/api/v1/corpus/briefing")
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["generated_from"]["total_nodes"] == 12
        assert body["top_communities"][0]["top_entities"][0]["name"] == "Acme"
        assert "Corpus Briefing" in body["markdown"]

    def test_briefing_failure_is_500(self, client, monkeypatch):
        def boom(tenant_id):
            raise RuntimeError("neo4j down")

        monkeypatch.setattr(routes, "build_briefing", boom)
        assert client.get("/api/v1/corpus/briefing").status_code == 500


class TestDbtIngestRoute:
    def test_ingest_valid_manifest(self, client, monkeypatch):
        seen = {}

        def fake_write(graph, tenant_id):
            seen["nodes"] = len(graph.nodes)
            seen["tenant"] = tenant_id
            return {"nodes_written": len(graph.nodes), "edges_written": len(graph.edges)}

        monkeypatch.setattr(routes, "_write_dbt_graph", fake_write)
        manifest = {
            "nodes": {
                "model.proj.users": {
                    "resource_type": "model",
                    "name": "users",
                    "config": {"materialized": "table"},
                    "columns": {"id": {"name": "id", "data_type": "int"}},
                    "depends_on": {"nodes": []},
                }
            },
            "sources": {},
        }
        resp = client.post("/api/v1/dbt/ingest", json={"manifest": manifest})
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["status"] == "ok"
        assert body["nodes_written"] >= 1
        assert seen["tenant"] == "tenant-1"

    def test_ingest_rejects_manifest_without_nodes(self, client):
        resp = client.post("/api/v1/dbt/ingest", json={"manifest": {"sources": {}}})
        assert resp.status_code == 400

    def test_ingest_rejects_non_object_manifest(self, client):
        resp = client.post("/api/v1/dbt/ingest", json={"manifest": [1, 2]})
        assert resp.status_code == 422


class TestDatasetSearchRoute:
    def test_search_returns_matches(self, client, monkeypatch):
        monkeypatch.setattr(
            routes,
            "dataset_discovery",
            lambda q, tenant_id: {"query": q, "matches": [{"name": "users"}]},
        )
        resp = client.get("/api/v1/dbt/datasets", params={"q": "users"})
        assert resp.status_code == 200
        assert resp.json()["matches"][0]["name"] == "users"

    def test_search_empty_query(self, client, monkeypatch):
        monkeypatch.setattr(
            routes,
            "dataset_discovery",
            lambda q, tenant_id: {"query": q, "matches": []},
        )
        resp = client.get("/api/v1/dbt/datasets")
        assert resp.status_code == 200
        assert resp.json()["matches"] == []
