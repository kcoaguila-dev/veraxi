"""
backend/tests/test_quota.py

Tests for the tenant quota enforcement module (backend/storage/quota.py)
and the MCP server handler guards.

No real Neo4j or Qdrant connection — all storage calls are mocked.
"""
from unittest.mock import MagicMock, patch

import pytest
from backend.config import Config
from backend.storage.quota import check_tenant_hard_cap
from fastapi import HTTPException

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_config(max_nodes: int = 1000, auth_enabled: bool = True) -> Config:
    """Build a minimal Config with just the fields quota.py needs."""
    cfg = MagicMock(spec=Config)
    cfg.max_tenant_nodes = max_nodes
    cfg.auth_enabled = auth_enabled
    return cfg


def _mock_neo4j(node_count: int):
    """Return a patched Neo4jStorageClient that reports node_count."""
    mock_client = MagicMock()
    mock_client.execute_read.return_value = [{"count": node_count}]
    return mock_client


# ---------------------------------------------------------------------------
# check_tenant_hard_cap
# ---------------------------------------------------------------------------

class TestCheckTenantHardCap:
    def test_under_cap_does_not_raise(self):
        config = _make_config(max_nodes=1000)
        with patch("backend.storage.quota.Neo4jStorageClient.from_config",
                   return_value=_mock_neo4j(500)):
            check_tenant_hard_cap("tenant-1", config)  # should not raise

    def test_at_cap_raises_403(self):
        config = _make_config(max_nodes=1000)
        with patch("backend.storage.quota.Neo4jStorageClient.from_config",  # noqa: SIM117
                   return_value=_mock_neo4j(1000)):
            with pytest.raises(HTTPException) as exc_info:
                check_tenant_hard_cap("tenant-1", config)
        assert exc_info.value.status_code == 403
        assert "Free Tier quota" in exc_info.value.detail

    def test_over_cap_raises_403(self):
        config = _make_config(max_nodes=1000)
        with patch("backend.storage.quota.Neo4jStorageClient.from_config",  # noqa: SIM117
                   return_value=_mock_neo4j(1500)):
            with pytest.raises(HTTPException) as exc_info:
                check_tenant_hard_cap("tenant-1", config)
        assert exc_info.value.status_code == 403

    def test_error_message_contains_node_limit(self):
        config = _make_config(max_nodes=500)
        with patch("backend.storage.quota.Neo4jStorageClient.from_config",  # noqa: SIM117
                   return_value=_mock_neo4j(600)):
            with pytest.raises(HTTPException) as exc_info:
                check_tenant_hard_cap("tenant-1", config)
        assert "500" in exc_info.value.detail

    def test_neo4j_error_is_swallowed_not_raised(self):
        """Storage errors must not crash callers — quota.py logs and moves on."""
        config = _make_config(max_nodes=1000)
        broken_client = MagicMock()
        broken_client.execute_read.side_effect = RuntimeError("Neo4j unavailable")
        with patch("backend.storage.quota.Neo4jStorageClient.from_config",
                   return_value=broken_client):
            # Should NOT raise — fail open so a Neo4j hiccup doesn't block all writes
            check_tenant_hard_cap("tenant-1", config)


# ---------------------------------------------------------------------------
# MCP handler guards (_handle_insert_graph_nodes / _handle_insert_vectors)
# ---------------------------------------------------------------------------

class TestMcpInsertHandlerQuota:
    """Verify that the MCP insert handlers call the quota check on cloud and
    skip it on self-hosted deployments."""

    def test_insert_graph_nodes_enforces_cap_on_cloud(self):
        from backend.mcp_server.server import _handle_insert_graph_nodes
        with patch("backend.mcp_server.server.get_config",
                   return_value=_make_config(max_nodes=1000, auth_enabled=True)), \
             patch("backend.mcp_server.server.check_tenant_hard_cap",
                   side_effect=HTTPException(status_code=403, detail="quota")) as mock_cap, \
             pytest.raises(HTTPException):
            _handle_insert_graph_nodes({"nodes": [], "relations": []}, "cloud-user")
        mock_cap.assert_called_once()

    def test_insert_graph_nodes_skips_cap_on_self_hosted(self):
        from backend.mcp_server.server import _handle_insert_graph_nodes
        with patch("backend.mcp_server.server.get_config",
                   return_value=_make_config(auth_enabled=False)), \
             patch("backend.mcp_server.server.check_tenant_hard_cap") as mock_cap, \
             patch("backend.mcp_server.server.insert_graph_nodes",
                   return_value={"status": "success", "nodes_inserted": 0, "relations_inserted": 0}):
            _handle_insert_graph_nodes({"nodes": [], "relations": []}, "local_personal_user")
        mock_cap.assert_not_called()

    def test_insert_vectors_enforces_cap_on_cloud(self):
        from backend.mcp_server.server import _handle_insert_vectors
        with patch("backend.mcp_server.server.get_config",
                   return_value=_make_config(max_nodes=1000, auth_enabled=True)), \
             patch("backend.mcp_server.server.check_tenant_hard_cap",
                   side_effect=HTTPException(status_code=403, detail="quota")) as mock_cap, \
             pytest.raises(HTTPException):
            _handle_insert_vectors({"texts": ["hello"]}, "cloud-user")
        mock_cap.assert_called_once()

    def test_insert_vectors_skips_cap_on_self_hosted(self):
        from backend.mcp_server.server import _handle_insert_vectors
        with patch("backend.mcp_server.server.get_config",
                   return_value=_make_config(auth_enabled=False)), \
             patch("backend.mcp_server.server.check_tenant_hard_cap") as mock_cap, \
             patch("backend.mcp_server.server.insert_vectors",
                   return_value={"status": "success", "vectors_inserted": 0, "point_ids": []}):
            _handle_insert_vectors({"texts": []}, "local_personal_user")
        mock_cap.assert_not_called()
