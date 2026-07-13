from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import logging
from backend.mcp_server.llm_loop import answer_question

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
