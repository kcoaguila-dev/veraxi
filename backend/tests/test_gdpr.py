from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.api_gateway import app, get_tenant_id


# Mock the dependency to return a static tenant ID
def override_get_tenant_id():
    return "test_tenant_id"

app.dependency_overrides[get_tenant_id] = override_get_tenant_id

client = TestClient(app)

class MockRedis:
    async def smembers(self, *args, **kwargs):
        return []

    async def hgetall(self, *args, **kwargs):
        return {}
        
    async def delete(self, *args, **kwargs):
        return 1

@pytest.fixture
def override_redis(monkeypatch):
    monkeypatch.setattr(app.state, "redis", MockRedis(), raising=False)

@pytest.mark.asyncio
async def test_export_user_data(override_redis):
    # Mock AsyncRedisSaver to prevent connecting to a real Redis instance
    with patch("langgraph.checkpoint.redis.aio.AsyncRedisSaver.from_conn_string") as mock_saver:
        mock_memory = AsyncMock()
        mock_saver.return_value.__aenter__.return_value = mock_memory
        
        response = client.get("/api/user/export")
        assert response.status_code == 200
        data = response.json()
        assert data["tenant_id"] == "test_tenant_id"
        assert "export_date" in data
        assert data["threads"] == []

@pytest.mark.asyncio
async def test_delete_user_data(override_redis):
    # Mock Neo4jStorageClient and QdrantStorageClient
    with patch("backend.api_gateway.Neo4jStorageClient") as mock_neo4j_cls, \
         patch("backend.api_gateway.QdrantStorageClient") as mock_qdrant_cls:
         
        mock_neo4j = MagicMock()
        mock_neo4j_cls.return_value = mock_neo4j
        
        mock_qdrant = MagicMock()
        mock_qdrant_cls.return_value = mock_qdrant
        
        response = client.delete("/api/user/data")
        assert response.status_code == 200
        
        # Verify Neo4j was called to delete tenant data
        mock_neo4j._driver.execute_query.assert_called_once()
        args, _kwargs = mock_neo4j._driver.execute_query.call_args
        assert "WHERE n.tenant_id = $tenant_id" in args[0]
        assert args[1]["tenant_id"] == "test_tenant_id"
        
        # Verify Qdrant was called to delete tenant data
        mock_qdrant.client.delete.assert_called_once()
        _qdrant_args, qdrant_kwargs = mock_qdrant.client.delete.call_args
        assert qdrant_kwargs["collection_name"] == mock_qdrant.collection_name
