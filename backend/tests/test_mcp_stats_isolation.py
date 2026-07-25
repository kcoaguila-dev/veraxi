import pytest
from backend.mcp_server.tools.get_stats import get_database_stats
from backend.mcp_server.server import _handle_get_database_stats
from unittest.mock import patch

@patch("backend.mcp_server.tools.get_stats.Neo4jStorageClient")
@patch("backend.mcp_server.tools.get_stats.QdrantStorageClient")
@patch("backend.mcp_server.tools.get_stats.get_config")
def test_get_database_stats_isolation(mock_config, mock_qdrant, mock_neo4j):
    # Setup mock config
    mock_config_instance = mock_config.return_value
    mock_config_instance.qdrant_collection_name = "veraxi_docs"
    
    # Mock the database clients to return dummy stats
    mock_neo4j_instance = mock_neo4j.from_config.return_value
    mock_neo4j_instance.execute_read.side_effect = [
        [{"node_count": 5}],  # node query result
        [{"rel_count": 10}]   # rel query result
    ]
    
    mock_qdrant_instance = mock_qdrant.from_config.return_value
    mock_qdrant_instance.count.return_value = 15
    
    # 1. Test direct function call
    tenant_a = "tenant_a_123"
    stats_a = get_database_stats(tenant_id=tenant_a)
    
    # Verify the exact tenant ID was passed to Qdrant (preventing the "default" leak)
    mock_qdrant_instance.count.assert_called_with("veraxi_docs", tenant_id=tenant_a)
    
    # 2. Test through the MCP tool handler
    tenant_b = "tenant_b_456"
    result = _handle_get_database_stats({}, tenant_id=tenant_b)
    
    # Verify the MCP tool handler passed it down correctly
    mock_qdrant_instance.count.assert_called_with("veraxi_docs", tenant_id=tenant_b)
