import os
import pytest
from testcontainers.neo4j import Neo4jContainer
from testcontainers.qdrant import QdrantContainer
from backend.config import get_config


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

    # Needs a dummy key for Anthropic if not set, else config fails
    if not os.environ.get("LLM_API_KEY"):
        monkeypatch.setenv("LLM_API_KEY", "test-dummy-key")

    if not os.environ.get("ANTHROPIC_API_KEY"):
        monkeypatch.setenv("ANTHROPIC_API_KEY", "test-dummy-key")

    # Clear the config lru_cache so it picks up the new env vars
    get_config.cache_clear()

    yield
