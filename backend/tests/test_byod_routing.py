import pytest
from fastapi.testclient import TestClient
from backend.api_gateway import app
from backend.config import Config
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient
from backend import context as byod_context

# Mock config for testing
@pytest.fixture
def mock_config():
    # Use a dummy config with default fallback values
    return Config(
        neo4j_uri="bolt://default-neo4j:7687",
        neo4j_user="default-neo-user",
        neo4j_password="default-neo-password",
        qdrant_url="http://default-qdrant:6333",
        qdrant_api_key="default-qdrant-key",
        # the rest of the Config attributes are not strictly required for these specific tests
        # but the Config class dataclass initialization might require them if we instantiate it.
        # However, to avoid needing to mock all 20+ fields, we can just mock an object.
        qdrant_collection_name="veraxi_docs",
        llm_api_key="x", llm_base_url="x", llm_model_name="x",
        embedding_api_key="x", embedding_model_name="x",
        sentry_dsn="", stripe_api_key="x", stripe_webhook_secret="x",
        supabase_url="x", supabase_service_key="x", postgres_url="x",
        rate_limit_chat="x", rate_limit_ingest="x", rate_limit_sse="x",
        default_search_limit=10, default_max_hops=2, searxng_url="x",
        redis_url="x", auth_enabled=False, cors_origins="*",
        gpt_sovits_base_url="x", code_interpreter_url="x", is_enterprise=False,
        help_faq_url="x", terms_of_service_url="x", privacy_policy_url="x", max_tenant_nodes=1000
    )


def test_neo4j_client_uses_byod_context(mock_config):
    # Setup context vars
    token1 = byod_context.request_neo4j_uri.set("bolt://byod-neo4j:7687")
    token2 = byod_context.request_neo4j_user.set("byod-neo-user")
    token3 = byod_context.request_neo4j_pass.set("byod-neo-pass")
    
    try:
        # We don't want it to actually connect, so we mock driver creation or just check the properties.
        # But Neo4jStorageClient connects on init (`self.driver = GraphDatabase.driver(...)`).
        # We can patch GraphDatabase.driver.
        import unittest.mock
        with unittest.mock.patch("backend.storage.neo4j_client.GraphDatabase.driver") as mock_driver:
            client = Neo4jStorageClient.from_config(mock_config)
            
            # Assert it used BYOD credentials
            mock_driver.assert_called_once_with(
                "bolt://byod-neo4j:7687", 
                auth=("byod-neo-user", "byod-neo-pass")
            )
    finally:
        byod_context.request_neo4j_uri.reset(token1)
        byod_context.request_neo4j_user.reset(token2)
        byod_context.request_neo4j_pass.reset(token3)


def test_neo4j_client_falls_back_to_config(mock_config):
    # Context vars are default (None)
    import unittest.mock
    with unittest.mock.patch("backend.storage.neo4j_client.GraphDatabase.driver") as mock_driver:
        client = Neo4jStorageClient.from_config(mock_config)
        
        # Assert it used config credentials
        mock_driver.assert_called_once_with(
            "bolt://default-neo4j:7687", 
            auth=("default-neo-user", "default-neo-password")
        )


def test_qdrant_client_uses_byod_context(mock_config):
    # Setup context vars
    token1 = byod_context.request_qdrant_url.set("http://byod-qdrant:6333")
    token2 = byod_context.request_qdrant_key.set("byod-qdrant-key")
    
    try:
        import unittest.mock
        with unittest.mock.patch("backend.storage.qdrant_client.QdrantClient") as mock_client:
            client = QdrantStorageClient.from_config(mock_config)
            
            # Assert it used BYOD credentials
            mock_client.assert_called_once_with(
                url="http://byod-qdrant:6333", 
                api_key="byod-qdrant-key"
            )
    finally:
        byod_context.request_qdrant_url.reset(token1)
        byod_context.request_qdrant_key.reset(token2)


def test_qdrant_client_falls_back_to_config(mock_config):
    # Context vars are default (None)
    import unittest.mock
    with unittest.mock.patch("backend.storage.qdrant_client.QdrantClient") as mock_client:
        client = QdrantStorageClient.from_config(mock_config)
        
        # Assert it used config credentials
        mock_client.assert_called_once_with(
            url="http://default-qdrant:6333", 
            api_key="default-qdrant-key"
        )


client = TestClient(app)

def test_byod_middleware_extracts_headers():
    # We will hit the /api/chat endpoint but we don't need it to succeed entirely, 
    # just enough to pass the middleware and we can mock something deeper to capture the context vars.
    # Alternatively, we can just write a dummy endpoint for testing or use a dependency override.
    
    # We can patch a function inside the endpoint to check the contextvars.
    # But it's easier to just mock get_config and have Neo4jStorageClient trap the uri.
    
    import unittest.mock
    from backend.api_gateway import byod_context
    
    # Create a small dummy route on the test app to inspect context vars
    @app.get("/test-byod-middleware")
    def get_context():
        return {
            "neo4j_uri": byod_context.request_neo4j_uri.get(),
            "neo4j_user": byod_context.request_neo4j_user.get(),
            "neo4j_pass": byod_context.request_neo4j_pass.get(),
            "qdrant_url": byod_context.request_qdrant_url.get(),
            "qdrant_key": byod_context.request_qdrant_key.get(),
        }

    response = client.get("/test-byod-middleware", headers={
        "X-BYOD-NEO4J-URI": "bolt://test:7687",
        "X-BYOD-NEO4J-USER": "test-user",
        "X-BYOD-NEO4J-PASS": "test-pass",
        "X-BYOD-QDRANT-URL": "http://test:6333",
        "X-BYOD-QDRANT-KEY": "test-key"
    })
    
    assert response.status_code == 200
    data = response.json()
    assert data["neo4j_uri"] == "bolt://test:7687"
    assert data["neo4j_user"] == "test-user"
    assert data["neo4j_pass"] == "test-pass"
    assert data["qdrant_url"] == "http://test:6333"
    assert data["qdrant_key"] == "test-key"

    # Test that it sets None if headers are missing
    response_empty = client.get("/test-byod-middleware")
    data_empty = response_empty.json()
    assert data_empty["neo4j_uri"] is None
    assert data_empty["neo4j_user"] is None
    assert data_empty["neo4j_pass"] is None
    assert data_empty["qdrant_url"] is None
    assert data_empty["qdrant_key"] is None

