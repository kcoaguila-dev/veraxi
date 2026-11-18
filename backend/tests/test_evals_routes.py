"""Route tests for POST /api/v1/evals/ablation.

Uses the recorded-rankings retriever exactly as the CLI does:
rankings are keyed by config name, then by query text.
"""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.routes import evals as routes

CASES = [
    {
        "id": "lookup-1",
        "query_type": "lookup",
        "query": "What is Acme?",
        "relevant_doc_ids": ["doc-1", "doc-2"],
    },
    {
        "id": "hop-1",
        "query_type": "multi_hop",
        "query": "How is Acme connected to Gamma?",
        "relevant_doc_ids": ["doc-3"],
    },
]

RANKINGS = {
    "vector_only": {
        "What is Acme?": ["doc-1"],
        "How is Acme connected to Gamma?": ["doc-9"],
    },
    "hybrid_no_graph": {
        "What is Acme?": ["doc-1", "doc-2"],
        "How is Acme connected to Gamma?": ["doc-9"],
    },
    "hybrid_with_graph": {
        "What is Acme?": {
            "ranked_doc_ids": ["doc-2", "doc-1"],
            "grounding_score": 0.9,
        },
        "How is Acme connected to Gamma?": {
            "ranked_doc_ids": ["doc-3"],
            "grounding_score": 0.8,
        },
    },
}


@pytest.fixture()
def client():
    app = FastAPI()
    routes.register_eval_routes(app, lambda: "tenant-1", lambda: None, None)
    return TestClient(app, raise_server_exceptions=False)


class TestAblationRoute:
    def test_run_returns_per_type_metrics(self, client):
        resp = client.post(
            "/api/v1/evals/ablation",
            json={"cases": CASES, "rankings": RANKINGS, "k": 5},
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        configs = body["configurations"]
        assert set(configs) == {
            "vector_only",
            "hybrid_no_graph",
            "hybrid_with_graph",
        }
        lookup = configs["vector_only"]["by_query_type"]["lookup"]
        assert lookup["case_count"] == 1
        assert lookup["recall_at_k"] == 0.5
        assert lookup["hit_rate"] == 1.0
        # Bare-list rankings carry no grounding → absent, not invented.
        assert lookup["grounding_score"] is None
        graph_lookup = configs["hybrid_with_graph"]["by_query_type"]["lookup"]
        assert graph_lookup["recall_at_k"] == 1.0
        assert graph_lookup["grounding_score"] == 0.9
        hop = configs["hybrid_with_graph"]["by_query_type"]["multi_hop"]
        assert hop["hit_rate"] == 1.0

    def test_dataset_object_form_accepted(self, client):
        resp = client.post(
            "/api/v1/evals/ablation",
            json={
                "dataset": {"name": "demo", "cases": CASES},
                "rankings": RANKINGS,
            },
        )
        assert resp.status_code == 200
        assert resp.json()["dataset"] == "demo"

    def test_invalid_case_rejected_400(self, client):
        bad = [{"id": "x", "query_type": "nope", "query": "q",
                "relevant_doc_ids": ["d"]}]
        resp = client.post(
            "/api/v1/evals/ablation", json={"cases": bad, "rankings": RANKINGS}
        )
        assert resp.status_code == 400

    def test_missing_dataset_rejected_400(self, client):
        resp = client.post(
            "/api/v1/evals/ablation", json={"rankings": RANKINGS}
        )
        assert resp.status_code == 400

    def test_empty_rankings_rejected_400(self, client):
        resp = client.post(
            "/api/v1/evals/ablation", json={"cases": CASES, "rankings": {}}
        )
        assert resp.status_code == 400
