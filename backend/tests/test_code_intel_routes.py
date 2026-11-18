"""Route tests for /api/v1/code/* and /api/v1/vuln/*.

Graph/network layers are faked by monkeypatching the functions the
routes module imported. Path validation is exercised for real
against a tmp repo, including adversarial traversal attempts that
must fail closed.
"""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.routes import code_intel as routes


@pytest.fixture()
def repo(tmp_path):
    (tmp_path / "pyproject.toml").write_text(
        '[project]\nname = "demo"\ndependencies = ["requests==2.31.0"]\n',
        encoding="utf-8",
    )
    (tmp_path / "app.py").write_text("def main():\n    return 1\n", encoding="utf-8")
    return tmp_path


@pytest.fixture()
def client(monkeypatch, repo):
    monkeypatch.setenv("VERAXI_CODE_ROOTS", str(repo.parent))
    app = FastAPI()
    routes.register_code_intel_routes(app, lambda: "tenant-1", lambda: None, None)
    return TestClient(app, raise_server_exceptions=False)


class TestPathValidation:
    def test_traversal_rejected(self, client):
        resp = client.post(
            "/api/v1/code/ingest", json={"repo_path": "/etc/../etc/passwd"}
        )
        assert resp.status_code in (400, 403)

    def test_dotdot_segment_rejected(self, client, repo):
        resp = client.post(
            "/api/v1/code/ingest",
            json={"repo_path": str(repo) + "/../secret"},
        )
        assert resp.status_code == 403

    def test_outside_roots_rejected(self, client):
        resp = client.post("/api/v1/code/ingest", json={"repo_path": "/etc"})
        assert resp.status_code == 403

    def test_missing_dir_inside_roots_is_404(self, client, repo):
        resp = client.post(
            "/api/v1/code/ingest",
            json={"repo_path": str(repo.parent / "does-not-exist")},
        )
        assert resp.status_code == 404


class TestCodeRoutes:
    def test_ingest_ok(self, client, monkeypatch, repo):
        seen = {}

        def fake_write(root, tenant_id="default", client=None):
            seen["root"] = str(root)
            seen["tenant"] = tenant_id
            return {"nodes_written": 5, "edges_written": 4}

        monkeypatch.setattr(routes, "write_repo_code_graph", fake_write)
        resp = client.post(
            "/api/v1/code/ingest", json={"repo_path": str(repo)}
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["nodes_written"] == 5
        assert seen["tenant"] == "tenant-1"

    def test_overview(self, client, monkeypatch):
        monkeypatch.setattr(
            routes,
            "repo_overview",
            lambda tenant_id: {
                "tenant_id": tenant_id,
                "node_counts": {"Function": 3},
                "edge_counts": {"CALLS": 2},
                "total_nodes": 3,
                "total_edges": 2,
                "top_connected": [],
            },
        )
        resp = client.get("/api/v1/code/overview")
        assert resp.status_code == 200
        assert resp.json()["total_nodes"] == 3

    def test_symbol(self, client, monkeypatch):
        monkeypatch.setattr(
            routes,
            "symbol_lookup",
            lambda name, tenant_id: {
                "query": name,
                "match_type": "name",
                "matches": [{"name": name}],
            },
        )
        resp = client.get("/api/v1/code/symbol", params={"name": "main"})
        assert resp.status_code == 200
        assert resp.json()["matches"][0]["name"] == "main"

    def test_impact(self, client, monkeypatch):
        monkeypatch.setattr(
            routes,
            "impact_analysis",
            lambda symbol, tenant_id, max_depth: {
                "symbol": symbol,
                "found": True,
                "roots": [],
                "max_depth": max_depth,
                "impacted": [{"qualified_name": "a.b", "depth": 1, "via_edge": "CALLS"}],
            },
        )
        resp = client.get(
            "/api/v1/code/impact", params={"symbol": "main", "max_depth": 2}
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["max_depth"] == 2
        assert body["impacted"][0]["via_edge"] == "CALLS"


class TestVulnRoutes:
    def test_sync(self, client, monkeypatch):
        monkeypatch.setattr(
            routes,
            "_sync_vuln_intel",
            lambda tenant_id: {"cves_written": 10, "packages_written": 3},
        )
        resp = client.post("/api/v1/vuln/sync")
        assert resp.status_code == 200
        assert resp.json()["cves_written"] == 10

    def test_report_from_repo_path(self, client, monkeypatch, repo):
        monkeypatch.setattr(
            routes,
            "vuln_report",
            lambda deps, tenant_id: {
                "dependencies_checked": len(deps),
                "findings": [],
                "matched_count": 0,
                "unknown_count": 0,
                "kev_count": 0,
                "tenant_id": tenant_id,
            },
        )
        resp = client.post(
            "/api/v1/vuln/report", json={"repo_path": str(repo)}
        )
        assert resp.status_code == 200, resp.text
        # The real extractor must have found requests in pyproject.toml.
        assert resp.json()["dependencies_checked"] >= 1

    def test_report_from_explicit_dependencies(self, client, monkeypatch):
        monkeypatch.setattr(
            routes,
            "vuln_report",
            lambda deps, tenant_id: {
                "dependencies_checked": len(deps),
                "findings": [
                    {
                        "package": "requests",
                        "version": "2.31.0",
                        "cve_id": "CVE-2024-0001",
                        "severity": "HIGH",
                        "kev": True,
                        "cwe_ids": ["CWE-79"],
                        "match_status": "matched",
                    }
                ],
                "matched_count": 1,
                "unknown_count": 0,
                "kev_count": 1,
                "tenant_id": tenant_id,
            },
        )
        resp = client.post(
            "/api/v1/vuln/report",
            json={"dependencies": [{"name": "requests", "version": "2.31.0"}]},
        )
        assert resp.status_code == 200
        finding = resp.json()["findings"][0]
        assert finding["match_status"] == "matched"
        assert finding["kev"] is True

    def test_report_requires_input(self, client):
        resp = client.post("/api/v1/vuln/report", json={})
        assert resp.status_code == 400

    def test_report_traversal_rejected(self, client):
        resp = client.post(
            "/api/v1/vuln/report", json={"repo_path": "/tmp/../etc"}
        )
        assert resp.status_code in (400, 403)
