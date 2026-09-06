import unittest.mock

import pytest
from backend.api_gateway import app
from backend.config import get_config
from fastapi.testclient import TestClient

client = TestClient(app)

@pytest.fixture
def mock_enterprise_config():
    # Mock config to simulate enterprise / auth enabled
    config = get_config()
    orig_ent = config.is_enterprise
    orig_auth = config.auth_enabled
    config.is_enterprise = True
    config.auth_enabled = True
    yield config
    config.is_enterprise = orig_ent
    config.auth_enabled = orig_auth

@pytest.fixture
def mock_oss_config():
    # Mock config to simulate self-hosted / auth disabled
    config = get_config()
    orig_ent = config.is_enterprise
    orig_auth = config.auth_enabled
    config.is_enterprise = False
    config.auth_enabled = False
    yield config
    config.is_enterprise = orig_ent
    config.auth_enabled = orig_auth

def test_oss_bypasses_byod_check(mock_oss_config, monkeypatch):
    # In OSS mode, they shouldn't hit the BYOD block
    # We hit an endpoint that uses verify_infrastructure_access, e.g. /api/admin/stats
    # We must mock get_tenant_id because auth_enabled might try to check JWT
    # Actually if auth_enabled is False, get_tenant_id returns "local_personal_user"
    
    with unittest.mock.patch("backend.api_gateway._get_supabase"), \
         unittest.mock.patch("backend.api_gateway.QdrantStorageClient.from_config"), \
         unittest.mock.patch("backend.api_gateway.Neo4jStorageClient.from_config"):
        response = client.get("/api/admin/stats")
                
                # Should pass the dependency and return 200 (or 500 if DB mock fails differently, but not 402)
        # Let's mock the entire get_stats function body if needed, but returning a simple dict from DB mock works.
        # The main thing is that it DOES NOT return 402 Payment Required.
        assert response.status_code != 402

def test_enterprise_free_user_blocked(mock_enterprise_config, monkeypatch):
    # We need to mock get_tenant_id to just return a dummy id
    import backend.api_gateway
    async def override_tenant_id():
        return "free_user_123"
    
    app.dependency_overrides[backend.api_gateway.get_tenant_id] = override_tenant_id
    
    # We need to mock redis so cache returns None
    class MockRedis:
        async def get(self, key):
            return None
        async def setex(self, key, time, val):
            pass
            
    app.state.redis = MockRedis()
    
    # We need to mock _fetch_sub to return False
    with unittest.mock.patch("backend.api_gateway._get_supabase") as mock_supa:
        mock_supa.return_value.table.return_value.select.return_value.eq.return_value.execute.return_value.data = [{"is_subscribed": False}]
        
        response = client.get("/api/admin/stats")
        assert response.status_code == 402
        assert "Payment Required" in response.json()["detail"]
        
    app.dependency_overrides.clear()

def test_enterprise_paid_user_allowed(mock_enterprise_config, monkeypatch):
    import backend.api_gateway
    async def override_tenant_id():
        return "paid_user_123"
    
    app.dependency_overrides[backend.api_gateway.get_tenant_id] = override_tenant_id
    
    # Mock redis to return "true"
    class MockRedis:
        async def get(self, key):
            return b"true"
            
    app.state.redis = MockRedis()
    
    with unittest.mock.patch("backend.api_gateway.QdrantStorageClient.from_config"), \
         unittest.mock.patch("backend.api_gateway.Neo4jStorageClient.from_config"):
        response = client.get("/api/admin/stats")
        # Should bypass 402
        assert response.status_code != 402
            
    app.dependency_overrides.clear()

def test_enterprise_free_user_with_byod_headers_allowed(mock_enterprise_config, monkeypatch):
    import backend.api_gateway
    async def override_tenant_id():
        return "free_user_123"
    
    app.dependency_overrides[backend.api_gateway.get_tenant_id] = override_tenant_id
    
    with unittest.mock.patch("backend.api_gateway.QdrantStorageClient.from_config"), \
         unittest.mock.patch("backend.api_gateway.Neo4jStorageClient.from_config"):
        # Provide headers to simulate BYOD
        response = client.get("/api/admin/stats", headers={
                "X-BYOD-NEO4J-URI": "bolt://test",
                "X-BYOD-QDRANT-URL": "http://test"
            })
        # Should bypass 402
        assert response.status_code != 402
            
    app.dependency_overrides.clear()
