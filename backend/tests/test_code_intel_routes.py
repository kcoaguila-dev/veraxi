"""Route tests for /api/v1/code/* and /api/v1/vuln/*.

Graph/network layers are faked by monkeypatching the functions the
routes module imported. Path validation is exercised for real
against a tmp repo, including adversarial traversal attempts that
must fail closed.
"""

import os

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

    def test_encoded_traversal_rejected(self, client):
        resp = client.post(
            "/api/v1/code/ingest", json={"repo_path": "%2f..%2fetc"}
        )
        assert resp.status_code == 403

    def test_symlink_escaping_root_rejected(
        self, client, repo, tmp_path_factory, monkeypatch
    ):
        monkeypatch.setenv("VERAXI_CODE_ROOTS", str(repo))
        outside = tmp_path_factory.mktemp("outside")
        (repo / "escape").symlink_to(outside, target_is_directory=True)
        resp = client.post(
            "/api/v1/code/ingest", json={"repo_path": str(repo / "escape")}
        )
        assert resp.status_code == 403

    def test_nested_subdir_inside_root_resolves(self, client, monkeypatch, repo):
        sub = repo / "nested"
        sub.mkdir()
        monkeypatch.setattr(
            routes,
            "write_repo_code_graph",
            lambda root, tenant_id="default", client=None: {
                "nodes_written": 1,
                "edges_written": 0,
            },
        )
        resp = client.post("/api/v1/code/ingest", json={"repo_path": str(sub)})
        assert resp.status_code == 200, resp.text
        assert resp.json()["repo_path"] == os.path.realpath(sub)


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

    def test_ingest_offloads_to_worker_thread(self, client, monkeypatch, repo):
        import threading

        seen = {}
        caller_thread = threading.get_ident()

        def fake_write(root, tenant_id="default", client=None):
            seen["worker_thread"] = threading.get_ident()
            return {"nodes_written": 1, "edges_written": 0}

        monkeypatch.setattr(routes, "write_repo_code_graph", fake_write)
        resp = client.post(
            "/api/v1/code/ingest", json={"repo_path": str(repo)}
        )
        assert resp.status_code == 200
        assert seen["worker_thread"] != caller_thread


class TestVulnLiveOsvFallback:
    def test_live_osv_fallback_when_graph_empty(self, client, monkeypatch):
        from backend.ingestion.vuln_intel import CVERecord, VersionRange

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
        record = CVERecord(
            id="GHSA-j8r2-6x86-q33q",
            aliases=["CVE-2023-32681"],
            severity="MODERATE",
            affected=[
                VersionRange(
                    criteria="osv:PyPI:requests:0-2.31.2",
                    product="requests",
                    ecosystem="PyPI",
                    introduced="0",
                    fixed="2.31.2",
                    version_end_excluding="2.31.2",
                )
            ],
        )
        monkeypatch.setattr(
            routes, "fetch_osv_for_packages", lambda deps: [record]
        )
        monkeypatch.setattr(
            routes,
            "fetch_kev_records",
            lambda: [{"cve_id": "CVE-2023-32681", "date_added": "2023-06-01"}],
        )
        resp = client.post(
            "/api/v1/vuln/report",
            json={
                "dependencies": [
                    {"name": "requests", "version": "2.31.0", "ecosystem": "pypi"}
                ],
                "live_osv": True,
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["matched_count"] == 1
        assert body["kev_count"] == 1
        assert body["source"] == "osv_live"

    def test_no_live_osv_by_default(self, client, monkeypatch):
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
        called = []
        monkeypatch.setattr(
            routes,
            "fetch_osv_for_packages",
            lambda deps: called.append(deps) or [],
        )
        resp = client.post(
            "/api/v1/vuln/report",
            json={"dependencies": [{"name": "requests", "version": "2.31.0"}]},
        )
        assert resp.status_code == 200
        assert called == []


class TestIngestGraphRoute:
    def test_ingest_graph_ok(self, client, monkeypatch):
        seen = {}

        def fake_write(payload, tenant_id):
            seen["repo"] = payload.repo_name
            seen["tenant"] = tenant_id
            seen["nodes"] = len(payload.nodes)
            return {"nodes_written": len(payload.nodes), "edges_written": len(payload.edges)}

        monkeypatch.setattr(routes, "_write_parsed_graph", fake_write)
        resp = client.post(
            "/api/v1/code/ingest-graph",
            json={
                "repo_name": "demo",
                "nodes": [
                    {"label": "Function", "name": "main",
                     "qualified_name": "veraxi.cli.main.main",
                     "path": "packages/veraxi-cli/src/veraxi/cli/main.py",
                     "line": 10, "language": "python", "resolved": True}
                ],
                "edges": [],
            },
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["nodes_written"] == 1
        assert seen == {"repo": "demo", "tenant": "tenant-1", "nodes": 1}

    def test_ingest_graph_oversized_rejected(self, client, monkeypatch):
        monkeypatch.setattr(routes, "MAX_INGEST_NODES", 1)
        resp = client.post(
            "/api/v1/code/ingest-graph",
            json={"repo_name": "demo", "nodes": [{"label": "Function"}, {"label": "Class"}], "edges": []},
        )
        assert resp.status_code == 413


class TestSarifAndSbomRoutes:
    def test_vuln_report_accepts_sbom_json(self, client, monkeypatch):
        seen = {}

        def fake_report(deps, tenant_id="default"):
            seen["deps"] = deps
            seen["tenant_id"] = tenant_id
            return {
                "dependencies_checked": len(deps),
                "findings": [],
                "matched_count": 0,
                "unknown_count": 0,
                "kev_count": 0,
                "tenant_id": tenant_id,
            }

        monkeypatch.setattr(routes, "vuln_report", fake_report)
        resp = client.post(
            "/api/v1/vuln/report",
            json={
                "sbom_json": {
                    "bomFormat": "CycloneDX",
                    "components": [
                        {"name": "gin", "version": "1.9.1", "purl": "pkg:golang/github.com/gin-gonic/gin@1.9.1"}
                    ],
                }
            },
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["dependencies_checked"] == 1
        assert seen["deps"][0]["ecosystem"] == "go"

    def test_ingest_sarif_route(self, client, monkeypatch):
        class FakeNeo4j:
            def __init__(self):
                self.calls = []

            def execute_write(self, query, params=None):
                self.calls.append((query, params or {}))
                return []

        fake_neo4j = FakeNeo4j()
        monkeypatch.setattr(routes, "_default_neo4j_client", lambda: fake_neo4j)
        monkeypatch.setattr(
            "backend.storage.qdrant_client.QdrantStorageClient.from_config",
            lambda cfg: (_ for _ in ()).throw(RuntimeError("no qdrant in unit test")),
        )
        resp = client.post(
            "/api/v1/vuln/sarif",
            json={
                "sarif": {
                    "version": "2.1.0",
                    "runs": [
                        {
                            "tool": {"driver": {"name": "Semgrep", "rules": []}},
                            "results": [
                                {
                                    "ruleId": "go.lang.security.sqli",
                                    "level": "error",
                                    "message": {"text": "SQL injection (CWE-89)"},
                                    "locations": [
                                        {
                                            "physicalLocation": {
                                                "artifactLocation": {"uri": "server.go"},
                                                "region": {"startLine": 12},
                                            }
                                        }
                                    ],
                                }
                            ],
                        }
                    ],
                }
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["status"] == "ok"
        assert body["findings_written"] == 1
        assert body["cwe_links"] == 1
        assert len(fake_neo4j.calls) == 3

    def test_sync_attack_intel_route(self, client, monkeypatch):
        class FakeNeo4j:
            def __init__(self):
                self.calls = []

            def execute_write(self, query, params=None):
                self.calls.append((query, params or {}))
                return []

        fake_neo4j = FakeNeo4j()
        monkeypatch.setattr(routes, "_default_neo4j_client", lambda: fake_neo4j)
        monkeypatch.setattr(
            "backend.storage.qdrant_client.QdrantStorageClient.from_config",
            lambda cfg: (_ for _ in ()).throw(RuntimeError("no qdrant in unit test")),
        )
        resp = client.post(
            "/api/v1/vuln/attack/sync",
            json={
                "stix_json": {
                    "type": "bundle",
                    "objects": [
                        {
                            "type": "attack-pattern",
                            "id": "attack-pattern--1",
                            "name": "Exploit Public-Facing Application",
                            "external_references": [
                                {"source_name": "mitre-attack", "external_id": "T1190"}
                            ],
                        }
                    ],
                }
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["status"] == "ok"
        assert body["techniques_written"] == 1

    def test_ingest_recon_route(self, client, monkeypatch):
        class FakeNeo4j:
            def __init__(self):
                self.calls = []

            def execute_write(self, query, params=None):
                self.calls.append((query, params or {}))
                return []

        fake_neo4j = FakeNeo4j()
        monkeypatch.setattr(routes, "_default_neo4j_client", lambda: fake_neo4j)
        monkeypatch.setattr(
            "backend.storage.qdrant_client.QdrantStorageClient.from_config",
            lambda cfg: (_ for _ in ()).throw(RuntimeError("no qdrant in unit test")),
        )
        resp = client.post(
            "/api/v1/vuln/recon",
            json={
                "nuclei": [
                    {
                        "template-id": "exposed-env",
                        "matched-at": "https://app.example.com/.env",
                        "info": {"name": "Exposed .env", "severity": "high"},
                    }
                ]
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["status"] == "ok"
        assert body["findings_written"] == 1
        assert body["host_links"] == 1
