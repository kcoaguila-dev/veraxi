from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
import logging
from backend.mcp_server.llm_loop import answer_question
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.ingestion.__main__ import run_ingestion
import sentry_sdk

logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)

config = get_config()
if config.sentry_dsn:
    sentry_sdk.init(
        dsn=config.sentry_dsn,
        traces_sample_rate=1.0,
        profiles_sample_rate=1.0,
    )

app = FastAPI(title="Veraxi API Gateway", description="Multi-Tenant SaaS HTTP Gateway for Phase 7")

# Allow Flutter app to communicate cross-origin
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

security = HTTPBearer(auto_error=False)

def get_tenant_id(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    if credentials:
        return credentials.credentials
    return "default"

class ChatRequest(BaseModel):
    question: str

class ChatResponse(BaseModel):
    answer: str

class IngestRequest(BaseModel):
    text: str

@app.post("/api/chat", response_model=ChatResponse)
async def chat_endpoint(request: ChatRequest, tenant_id: str = Depends(get_tenant_id)):
    logger.info(f"Received question: {request.question} for tenant: {tenant_id}")
    try:
        # The llm_loop functions are currently synchronous
        # In a high-throughput production environment, we'd run this in a threadpool
        answer = answer_question(request.question, tenant_id)
        return ChatResponse(answer=answer)
    except Exception as e:
        logger.error(f"Error processing question: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    return {"status": "ok"}

@app.get("/sentry-debug")
async def trigger_error():
    division_by_zero = 1 / int("0")

@app.get("/api/admin/stats")
def get_stats(tenant_id: str = Depends(get_tenant_id)):
    try:
        config = get_config()
        qdrant = QdrantStorageClient(url=config.qdrant_url, api_key=config.qdrant_api_key)
        neo4j = Neo4jStorageClient(uri=config.neo4j_uri, user=config.neo4j_user, password=config.neo4j_password)

        # Get Qdrant stats
        try:
            # We would typically filter by tenant_id, but the collection stats doesn't support easy payload filtering counts
            # For this MVP phase 7, we'll just do a scroll or assume the stats are global unless we run a count query.
            # Qdrant client natively supports count with filter:
            from qdrant_client.http import models
            filter = models.Filter(must=[models.FieldCondition(key="tenant_id", match=models.MatchValue(value=tenant_id))])
            count_result = qdrant.client.count(collection_name="veraxi_docs", count_filter=filter)
            vector_count = count_result.count
        except Exception as e:
            logger.warning(f"Failed to get qdrant stats: {e}")
            vector_count = 0

        # Get Neo4j stats
        try:
            records = neo4j.execute_read(
                "MATCH (n) WHERE n.tenant_id = $tenant_id RETURN count(n) AS count",
                parameters={"tenant_id": tenant_id}
            )
            node_count = records[0]["count"] if records else 0
        except Exception as e:
            logger.warning(f"Failed to get neo4j stats: {e}")
            node_count = 0
        finally:
            neo4j.close()

        return {
            "node_count": node_count,
            "vector_count": vector_count,
            "tenant_id": tenant_id
        }
    except Exception as e:
        logger.error(f"Error getting stats: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/admin/ingest")
def ingest_data(request: IngestRequest, tenant_id: str = Depends(get_tenant_id)):
    try:
        config = get_config()
        result = run_ingestion(config, request.text, tenant_id)
        return result
    except Exception as e:
        logger.error(f"Error during ingestion: {e}")
        raise HTTPException(status_code=500, detail=str(e))
