from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from backend.api_gateway import app, get_tenant_id
from fastapi.testclient import TestClient


# Override the auth dependency for testing
async def override_get_tenant_id():
    return "test_tenant_id"

app.dependency_overrides[get_tenant_id] = override_get_tenant_id

@pytest.fixture
def mock_redis():
    mock = AsyncMock()
    mock.sadd.return_value = 1
    mock.hset.return_value = None
    mock.close = AsyncMock()
    # Mock create_pool to return our mock redis instance
    with patch("backend.api_gateway.create_pool", new_callable=AsyncMock) as mock_create_pool:
        mock_create_pool.return_value = mock
        yield mock

@pytest.fixture
def client(mock_redis):
    with TestClient(app) as client:
        yield client

@patch("backend.api_gateway.moderate_text")
@patch("backend.api_gateway.answer_question")
@patch("backend.api_gateway.generate_chat_title")
def test_chat_endpoint_non_streaming(mock_gen_title, mock_answer, mock_moderate, client):
    mock_moderate.return_value = False
    mock_answer.return_value = (
        "Hello World",
        "Context",
        {"grounding_score": 0.95, "duration": 1.2}
    )
    mock_gen_title.return_value = "Test Title"

    response = client.post(
        "/api/chat",
        json={"question": "What is AI?", "stream": False, "model": "gpt-4o"}
    )

    assert response.status_code == 200
    data = response.json()
    assert data["answer"] == "Hello World"
    assert "thread_id" in data
    assert data["grounding_score"] == 0.95

@patch("backend.api_gateway.moderate_text")
def test_chat_endpoint_flagged_content(mock_moderate, client):
    mock_moderate.return_value = True

    response = client.post(
        "/api/chat",
        json={"question": "Bad stuff", "stream": False, "model": "gpt-4o"}
    )

    assert response.status_code == 400
    assert "flagged" in response.json()["detail"]

@patch("backend.api_gateway.moderate_text")
@patch("backend.api_gateway.stream_answer_question")
def test_chat_endpoint_streaming(mock_stream, mock_moderate, client):
    mock_moderate.return_value = False
    
    async def mock_stream_gen(*args, **kwargs):
        yield {"event": "token", "data": "Hello"}
        yield {"event": "token", "data": " World"}
        
    mock_stream.side_effect = mock_stream_gen

    response = client.post(
        "/api/chat",
        json={"question": "Hello?", "stream": True, "model": "gpt-4o"}
    )

    assert response.status_code == 200
    lines = [line for line in response.text.split("\n\n") if line.strip()]
    assert any("Hello" in line for line in lines)
    assert any("World" in line for line in lines)

@patch("backend.api_gateway.Neo4jStorageClient.from_config")
@patch("backend.api_gateway.QdrantStorageClient.from_config")
def test_admin_stats_endpoint(mock_qdrant_from_config, mock_neo4j_from_config, client):
    mock_neo4j = MagicMock()
    mock_neo4j.execute_read.return_value = [{"count": 100}]
    mock_neo4j_from_config.return_value = mock_neo4j
    
    mock_qdrant = MagicMock()
    mock_qdrant.client.count.return_value.count = 500
    mock_qdrant_from_config.return_value = mock_qdrant

    response = client.get("/api/admin/stats")
    
    assert response.status_code == 200
    data = response.json()
    assert data["node_count"] == 100
    assert data["vector_count"] == 500
    assert data["tenant_id"] == "test_tenant_id"

def test_health_endpoint(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"

def test_config_ui_endpoint(client):
    response = client.get("/api/config/ui")
    assert response.status_code == 200
    data = response.json()
    assert "help_faq_url" in data

def test_models_endpoint(client):
    response = client.get("/api/models")
    assert response.status_code == 200
    assert isinstance(response.json(), dict)

def test_chat_threads_endpoint(client, mock_redis):
    # Mock redis returning a list of thread IDs
    mock_redis.smembers.return_value = {b"thread1", b"thread2"}
    # Mock redis returning timestamps and titles
    mock_redis.hgetall.return_value = {b"thread1": b"1700000000.0", b"thread2": b"1700000010.0"}
    
    response = client.get("/api/chat/threads")
    assert response.status_code == 200
    assert len(response.json()["threads"]) == 2

@patch("backend.api_gateway._ensure_schema_exists")
@patch("backend.api_gateway.check_tenant_hard_cap")
def test_ingest_memory(mock_check_cap, mock_ensure_schema, client, mock_redis):
    mock_redis.enqueue_job.return_value = MagicMock(job_id="test_job_id")
    
    response = client.post(
        "/api/memory/ingest",
        json={
            "content": "I like to code in Python",
            "model": "gpt-4o"
        }
    )
    
    assert response.status_code == 200
    assert response.json()["status"] == "queued"
    assert response.json()["job_id"] == "test_job_id"
    
    # Verify the background job was queued with the correct preamble
    mock_redis.enqueue_job.assert_called_once()
    args = mock_redis.enqueue_job.call_args[0]
    assert args[0] == "process_ingestion_task"
    assert "The following is a verified long-term memory fact" in args[1]
    assert "I like to code in Python" in args[1]
    assert args[2] == "test_tenant_id"
    assert args[6] == "gpt-4o"

@pytest.mark.asyncio
async def test_ensure_schema_exists_missing():
    from backend.api_gateway import _ensure_schema_exists
    
    mock_redis = AsyncMock()
    mock_redis.get.return_value = None # Schema missing
    
    with patch("openai.AsyncOpenAI") as mock_openai:
        mock_client = AsyncMock()
        mock_response = MagicMock()
        mock_response.choices = [MagicMock(message=MagicMock(content='{"entities": [], "relations": {}}'))]
        mock_client.chat.completions.create.return_value = mock_response
        mock_openai.return_value = mock_client
        
        await _ensure_schema_exists(mock_redis, "test_tenant", "Sample document text")
        
        mock_client.chat.completions.create.assert_called_once()
        mock_redis.set.assert_called_once_with("tenant:test_tenant:schema", '{"entities": [], "relations": {}}')

@pytest.mark.asyncio
async def test_ensure_schema_exists_present():
    from backend.api_gateway import _ensure_schema_exists
    
    mock_redis = AsyncMock()
    mock_redis.get.return_value = '{"entities": ["Person"]}' # Schema exists
    
    with patch("openai.AsyncOpenAI") as mock_openai:
        await _ensure_schema_exists(mock_redis, "test_tenant", "Sample document text")
        
        # OpenAI should not be called if schema exists
        mock_openai.assert_not_called()
        mock_redis.set.assert_not_called()
