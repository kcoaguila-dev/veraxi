from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import logging
from backend.mcp_server.llm_loop import answer_question
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.ingestion.__main__ import run_ingestion

logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)

app = FastAPI(title="Veraxi API Gateway", description="Self-hostable HTTP Gateway for Phase 4")

# Allow Flutter app to communicate cross-origin
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class ChatRequest(BaseModel):
    question: str

class ChatResponse(BaseModel):
    answer: str

@app.post("/api/chat", response_model=ChatResponse)
async def chat_endpoint(request: ChatRequest):
    logger.info(f"Received question: {request.question}")
    try:
        # The llm_loop functions are currently synchronous
        # In a high-throughput production environment, we'd run this in a threadpool
        # But this is perfect for the Phase 4 walking skeleton
        answer = answer_question(request.question)
        return ChatResponse(answer=answer)
    except Exception as e:
        logger.error(f"Error processing question: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    return {"status": "ok"}

@app.get("/api/admin/stats")
def get_stats():
    try:
        config = get_config()
        qdrant = QdrantStorageClient(url=config.qdrant_url, api_key=config.qdrant_api_key)
        neo4j = Neo4jStorageClient(uri=config.neo4j_uri, user=config.neo4j_user, password=config.neo4j_password)

        # Get Qdrant stats
        try:
            qdrant_info = qdrant.client.get_collection("veraxi_docs")
            vector_count = qdrant_info.points_count
        except Exception as e:
            logger.warning(f"Failed to get qdrant stats: {e}")
            vector_count = 0

        # Get Neo4j stats
        try:
            records = neo4j.execute_read("MATCH (n) RETURN count(n) AS count")
            node_count = records[0]["count"] if records else 0
        except Exception as e:
            logger.warning(f"Failed to get neo4j stats: {e}")
            node_count = 0
        finally:
            neo4j.close()

        return {
            "node_count": node_count,
            "vector_count": vector_count
        }
    except Exception as e:
        logger.error(f"Error getting stats: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/admin/ingest")
def ingest_data():
    try:
        config = get_config()
        result = run_ingestion(config)
        return result
    except Exception as e:
        logger.error(f"Error during ingestion: {e}")
        raise HTTPException(status_code=500, detail=str(e))
