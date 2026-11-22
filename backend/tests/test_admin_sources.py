"""Tests for /api/admin/stats source_count and /api/admin/sources registry routes."""

from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.routes import admin as admin_routes
from backend.routes import ingestion as ingestion_routes
from backend.storage.source_registry import delete_tenant_source, list_tenant_sources


class _FakeConfig:
    qdrant_collection_name = "veraxi_vectors"
    worker_mode = "inline"
    rate_limit_ingest = "100/minute"
    document_parser = "simple"


class _FakeLimiter:
    def limit(self, *_args, **_kwargs):
        def decorator(fn):
            return fn

        return decorator


def _make_app():
    app = FastAPI()
    app.state.redis = AsyncMock()
    app.state.redis.hgetall.return_value = {
        b"job-1": b'{"job_id":"job-1","source":"arch.pdf","stage":"Chunking","progress":0.5}'
    }

    async def fake_tenant():
        return "tenant-1"

    admin_routes.register_admin_routes(
        app, fake_tenant, fake_tenant, _FakeLimiter(), _FakeConfig()
    )
    ingestion_routes.register_ingestion_routes(
        app, fake_tenant, fake_tenant, _FakeLimiter(), _FakeConfig()
    )
    return app


def test_list_and_delete_tenant_sources_dual_store():
    old_ts = (datetime.now(UTC) - timedelta(days=20)).isoformat()
    fresh_ts = datetime.now(UTC).isoformat()

    neo4j = MagicMock()

    def fake_read(query, parameters=None):
        if "MATCH (m:CodeIndexMeta" in query:
            return [
                {
                    "repo_key": "veraxi/backend",
                    "repo_root": "/repo/backend",
                    "source_commit": "abc",
                    "indexed_at": fresh_ts,
                }
            ]
        if "n.repo_key IS NOT NULL" in query:
            return [{"repo_key": "veraxi/backend", "files": 14, "symbols": 80}]
        if "n.qdrant_point_ids AS pids" in query:
            return [
                {"source": "guide.pdf", "pids": ["pt-1"]},
                {"source": None, "pids": ["pt-1", "pt-2"]},
            ]
        if "CVE" in query:
            return [{"cve_count": 42, "kev_count": 3, "last_modified": fresh_ts}]
        return []

    neo4j.execute_read.side_effect = fake_read
    neo4j.execute_write.return_value = [{"deleted": 2}]

    qdrant = MagicMock()
    qdrant.client.scroll.return_value = (
        [
            SimpleNamespace(
                id="pt-1",
                payload={
                    "source": "guide.pdf",
                    "source_type": "document",
                    "ingested_at": old_ts,
                },
            ),
            SimpleNamespace(
                id="pt-2",
                payload={
                    "source": "https://example.com/docs",
                    "source_type": "url",
                    "ingested_at": fresh_ts,
                },
            ),
        ],
        None,
    )

    sources = list_tenant_sources(
        "tenant-1", neo4j, qdrant, "veraxi_vectors", stale_days=14
    )
    by_id = {s["id"]: s for s in sources}
    assert by_id["veraxi/backend"]["category"] == "repo"
    assert by_id["veraxi/backend"]["counts"] == "14 files · 80 nodes"
    assert by_id["veraxi/backend"]["is_stale"] is False

    assert by_id["guide.pdf"]["is_stale"] is True
    assert by_id["guide.pdf"]["counts"] == "1 chunks · 2 nodes"

    assert by_id["https://example.com/docs"]["type"] == "URL"
    assert by_id["https://example.com/docs"]["is_stale"] is False

    assert by_id["nvd_kev_catalog"]["counts"] == "42 CVE · 3 KEV"

    # Deletion cleans up both Qdrant and Neo4j for document sources.
    qdrant.client.scroll.return_value = ([SimpleNamespace(id="pt-1")], None)
    deleted = delete_tenant_source(
        "tenant-1", "guide.pdf", "doc", neo4j, qdrant, "veraxi_vectors"
    )
    assert deleted == {"deleted_nodes": 2, "deleted_vectors": 1}
    qdrant.client.delete.assert_called_once()
    assert neo4j.execute_write.call_count >= 2


def test_admin_stats_and_sources_routes(monkeypatch):
    app = _make_app()
    client = TestClient(app)

    mock_neo4j = MagicMock()
    mock_neo4j.execute_read.return_value = [{"count": 321}]
    mock_qdrant = MagicMock()
    mock_qdrant.client.count.return_value = SimpleNamespace(count=184)

    sample_sources = [
        {
            "id": "veraxi/backend",
            "name": "veraxi/backend",
            "subtitle": "/repo/backend",
            "type": "Code AST",
            "category": "repo",
            "counts": "14 files · 80 nodes",
            "last_synced": "Just now",
            "is_stale": False,
        }
    ]

    with (
        patch.object(admin_routes, "get_config", return_value=_FakeConfig()),
        patch.object(
            admin_routes.Neo4jStorageClient, "from_config", return_value=mock_neo4j
        ),
        patch.object(
            admin_routes.QdrantStorageClient, "from_config", return_value=mock_qdrant
        ),
        patch.object(admin_routes, "list_tenant_sources", return_value=sample_sources),
        patch.object(ingestion_routes, "get_config", return_value=_FakeConfig()),
        patch.object(
            ingestion_routes.Neo4jStorageClient,
            "from_config",
            return_value=mock_neo4j,
        ),
        patch.object(
            ingestion_routes.QdrantStorageClient,
            "from_config",
            return_value=mock_qdrant,
        ),
        patch.object(
            ingestion_routes, "list_tenant_sources", return_value=sample_sources
        ),
        patch.object(
            ingestion_routes,
            "delete_tenant_source",
            return_value={"deleted_nodes": 5, "deleted_vectors": 4},
        ),
    ):
        stats_resp = client.get("/api/admin/stats")
        assert stats_resp.status_code == 200
        assert stats_resp.json()["node_count"] == 321
        assert stats_resp.json()["vector_count"] == 184
        assert stats_resp.json()["source_count"] == 1

        list_resp = client.get("/api/admin/sources")
        assert list_resp.status_code == 200
        assert len(list_resp.json()["sources"]) == 1
        assert len(list_resp.json()["queue"]) == 1

        del_resp = client.delete("/api/admin/sources?source_id=guide.pdf&category=doc")
        assert del_resp.status_code == 200
        assert del_resp.json()["deleted_nodes"] == 5
        assert del_resp.json()["deleted_vectors"] == 4
