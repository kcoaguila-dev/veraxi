import os
from unittest.mock import patch

import pytest
from backend.config import get_config
from testcontainers.neo4j import Neo4jContainer
from testcontainers.qdrant import QdrantContainer

# Set default dummy environment variables for pytest collection phase
# to prevent get_config() from crashing when modules are imported globally.
os.environ.setdefault("NEO4J_URI", "bolt://localhost:7687")
os.environ.setdefault("NEO4J_USER", "neo4j")
os.environ.setdefault("NEO4J_PASSWORD", "password")
os.environ.setdefault("QDRANT_URL", "http://localhost:6333")
os.environ.setdefault("LLM_API_KEY", "dummy-key")
os.environ.setdefault("ANTHROPIC_API_KEY", "dummy-key")
os.environ.setdefault("SUPABASE_URL", "http://localhost:8000")


@pytest.fixture(scope="session")
def neo4j_container():
    if os.environ.get("USE_TESTCONTAINERS", "true").lower() == "false":
        yield None
    else:
        with Neo4jContainer("neo4j:5") as neo4j:
            yield neo4j


@pytest.fixture(scope="session")
def qdrant_container():
    if os.environ.get("USE_TESTCONTAINERS", "true").lower() == "false":
        yield None
    else:
        with QdrantContainer("qdrant/qdrant:latest") as qdrant:
            yield qdrant


@pytest.fixture(autouse=True)
def mock_embed_text():
    """
    Mock the embed_text function to prevent downloading HuggingFace models
    during test runs, ensuring offline capability and fast execution.
    """
    with patch("backend.ingestion.entity_resolution.embed_text") as mock_er_embed, \
         patch("backend.mcp_server.tools.insert_vector.embed_text") as mock_iv_embed, \
         patch("backend.mcp_server.tools.search_vectors.embed_text") as mock_sv_embed, \
         patch("backend.ingestion.chunk_embed.embed_text") as mock_ce_embed:
        
        # Return a dummy vector of the expected size (384 for paraphrase-multilingual-MiniLM-L12-v2)
        dummy_embedding = [0.1] * 384
        mock_er_embed.return_value = dummy_embedding
        mock_iv_embed.return_value = dummy_embedding
        mock_sv_embed.return_value = dummy_embedding
        mock_ce_embed.return_value = dummy_embedding
        yield


@pytest.fixture
def patch_env(neo4j_container, qdrant_container, monkeypatch):
    """
    Override environment variables to point to the testcontainers instead
    of the live database.
    """
    if os.environ.get("USE_TESTCONTAINERS", "true").lower() != "false":
        neo4j_url = neo4j_container.get_connection_url()
        neo4j_user = "neo4j"
        neo4j_password = neo4j_container.password

        qdrant_url = f"http://{qdrant_container.rest_host_address}"

        monkeypatch.setenv("NEO4J_URI", neo4j_url)
        monkeypatch.setenv("NEO4J_USER", neo4j_user)
        monkeypatch.setenv("NEO4J_PASSWORD", neo4j_password)
        monkeypatch.setenv("QDRANT_URL", qdrant_url)
        monkeypatch.setenv("QDRANT_API_KEY", "")

    # Ensure REDIS_URL points to localhost for host-based pytest runs
    monkeypatch.setenv("REDIS_URL", "redis://localhost:6379/0")

    # Needs a dummy key for Anthropic if not set, else config fails
    if not os.environ.get("LLM_API_KEY"):
        monkeypatch.setenv("LLM_API_KEY", "test-dummy-key")

    if not os.environ.get("ANTHROPIC_API_KEY"):
        monkeypatch.setenv("ANTHROPIC_API_KEY", "test-dummy-key")

    # Clear the config lru_cache so it picks up the new env vars
    get_config.cache_clear()

    yield
