from fastapi import FastAPI, HTTPException, Depends, UploadFile, File, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
import logging
from backend.mcp_server.llm_loop import answer_question
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.ingestion.__main__ import run_ingestion
from backend.mcp_server.server import mcp_server
from backend.mcp_server.context import tenant_context
from mcp.server.sse import SseServerTransport
import sentry_sdk
import tempfile
import os
from docling.document_converter import DocumentConverter
import jwt
from jwt import PyJWKClient
import magic
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
import stripe
from supabase import create_client, Client

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

config = get_config()
if config.sentry_dsn:
    sentry_sdk.init(
        dsn=config.sentry_dsn,
        traces_sample_rate=1.0,
        profiles_sample_rate=1.0,
    )

# Configure the JWKS client to automatically download and cache public keys
jwks_url = f"{config.supabase_url}/auth/v1/.well-known/jwks.json"
jwks_client = PyJWKClient(jwks_url)

app = FastAPI(
    title="Veraxi API Gateway", 
    description="Multi-Tenant SaaS HTTP Gateway",
    version="1.0.0"
)

def get_auth_token_key(request: Request) -> str:
    auth = request.headers.get("Authorization")
    if auth and auth.startswith("Bearer "):
        return auth[7:]
    return get_remote_address(request)

limiter = Limiter(key_func=get_auth_token_key)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# Allow Flutter app to communicate cross-origin
# TODO(Production): Change allow_origins=["*"] to your exact Flutter web URL (e.g., ["https://app.veraxi.com"])
# to prevent unauthorized websites from making requests to this API.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

security = HTTPBearer(auto_error=True)

def _get_jwt_payload(token: str) -> dict:
    try:
        signing_key = jwks_client.get_signing_key_from_jwt(token)
        return jwt.decode(
            token, 
            signing_key.key, 
            algorithms=["ES256", "RS256", "HS256"],
            audience="authenticated"
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token has expired")
    except jwt.InvalidAudienceError:
        raise HTTPException(status_code=401, detail="Invalid audience. Expected 'authenticated'.")
    except jwt.InvalidTokenError as e:
        logger.warning(f"JWT Validation Error: {e}")
        raise HTTPException(status_code=401, detail="Invalid token")

def _decode_and_validate_jwt(token: str) -> str:
    payload = _get_jwt_payload(token)
    tenant_id = payload.get("sub")
    if not tenant_id:
        raise HTTPException(status_code=401, detail="Invalid token: missing sub (user ID) claim")
    return tenant_id

def get_tenant_id(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    return _decode_and_validate_jwt(credentials.credentials)


class ChatRequest(BaseModel):
    question: str
    calculate_grounding: bool = False


class ChatResponse(BaseModel):
    answer: str
    context: str | None = None
    grounding_score: float | None = None


class IngestRequest(BaseModel):
    text: str


@app.post("/api/chat", response_model=ChatResponse)
@limiter.limit(config.rate_limit_chat)
async def chat_endpoint(request: Request, chat_request: ChatRequest, tenant_id: str = Depends(get_tenant_id)):
    logger.info(f"Received question: {chat_request.question} for tenant: {tenant_id}")
    try:
        # The llm_loop functions are currently synchronous
        # In a high-throughput production environment, we'd run this in a threadpool
        answer, context = answer_question(chat_request.question, tenant_id, return_context=True)
        
        score = None
        if chat_request.calculate_grounding:
            from backend.evaluation.grounding import evaluate_groundedness
            score = evaluate_groundedness(answer, context)
            
        return ChatResponse(answer=answer, context=context, grounding_score=score)
    except Exception as e:
        logger.error(f"Error processing question: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
async def health_check():
    return {"status": "ok"}


@app.get("/sentry-debug")
async def trigger_error():
    _ = 1 / int("0")


@app.get("/api/admin/stats")
def get_stats(tenant_id: str = Depends(get_tenant_id)):
    try:
        config = get_config()
        qdrant = QdrantStorageClient(
            url=config.qdrant_url, api_key=config.qdrant_api_key
        )
        neo4j = Neo4jStorageClient(
            uri=config.neo4j_uri, user=config.neo4j_user, password=config.neo4j_password
        )

        stats = {}
        # Get Qdrant stats
        try:
            qdrant = QdrantStorageClient(url=config.qdrant_url, api_key=config.qdrant_api_key)
            from qdrant_client.http import models

            filter = models.Filter(must=[models.FieldCondition(key="tenant_id", match=models.MatchValue(value=tenant_id))])
            COLLECTION_NAME = config.qdrant_collection_name
            qdrant_points = qdrant.client.count(
                collection_name=COLLECTION_NAME, count_filter=filter
            )
            vector_count = qdrant_points.count
            stats["qdrant_points"] = vector_count
        except Exception as e:
            logger.warning(f"Failed to get qdrant stats: {e}")
            vector_count = 0

        # Get Neo4j stats
        try:
            records = neo4j.execute_read(
                "MATCH (n) WHERE n.tenant_id = $tenant_id RETURN count(n) AS count",
                parameters={"tenant_id": tenant_id},
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
            "tenant_id": tenant_id,
        }
    except Exception as e:
        logger.error(f"Error getting stats: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/admin/ingest")
@limiter.limit(config.rate_limit_ingest)
def ingest_data(request: Request, ingest_request: IngestRequest, tenant_id: str = Depends(get_tenant_id)):
    try:
        config = get_config()
        result = run_ingestion(config, ingest_request.text, tenant_id)
        return result
    except Exception as e:
        logger.error(f"Error during ingestion: {e}")
        raise HTTPException(status_code=500, detail=str(e))


class UrlIngestRequest(BaseModel):
    url: str


@app.post("/api/admin/ingest/upload")
@limiter.limit(config.rate_limit_ingest)
async def ingest_upload(
    request: Request, file: UploadFile = File(...), tenant_id: str = Depends(get_tenant_id)
):
    try:
        # Save uploaded file to temp file
        _, file_extension = os.path.splitext(file.filename)
        with tempfile.NamedTemporaryFile(
            delete=False, suffix=file_extension
        ) as tmp_file:
            content = await file.read()
            tmp_file.write(content)
            tmp_path = tmp_file.name

        # Magic Bytes Validation
        mime_type = magic.from_file(tmp_path, mime=True)
        allowed_mimes = [
            "application/pdf", "text/plain", "text/markdown", "text/html",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/msword",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-excel",
            "image/png", "image/jpeg", "image/tiff", "image/bmp"
        ]
        if mime_type not in allowed_mimes:
            os.unlink(tmp_path)
            logger.warning(f"File upload blocked. Invalid magic bytes detected: {mime_type} for file {file.filename}")
            raise HTTPException(
                status_code=400, 
                detail="Invalid file type. Supported formats: PDF, Word, PowerPoint, Excel, HTML, Text, and Images (PNG/JPG)."
            )

        config = get_config()
        logger.info(f"Converting file {file.filename} with Docling...")
        converter = DocumentConverter()
        result = converter.convert(tmp_path)
        markdown_text = result.document.export_to_markdown()

        # Clean up temp file
        os.unlink(tmp_path)

        logger.info(
            f"Ingesting {len(markdown_text)} bytes of markdown from {file.filename}"
        )
        ingestion_result = run_ingestion(config, markdown_text, tenant_id)
        return ingestion_result
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error during file ingestion: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/admin/ingest/url")
@limiter.limit(config.rate_limit_ingest)
def ingest_url(request: Request, url_request: UrlIngestRequest, tenant_id: str = Depends(get_tenant_id)):
    try:
        config = get_config()
        logger.info(f"Converting URL {url_request.url} with Docling...")
        converter = DocumentConverter()
        result = converter.convert(url_request.url)
        markdown_text = result.document.export_to_markdown()

        logger.info(
            f"Ingesting {len(markdown_text)} bytes of markdown from {url_request.url}"
        )
        ingestion_result = run_ingestion(config, markdown_text, tenant_id)
        return ingestion_result
    except Exception as e:
        logger.error(f"Error during URL ingestion: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# MCP SSE Transport Layer
# ==========================================

sse = SseServerTransport("/messages")

@app.get("/sse")
@limiter.limit(config.rate_limit_sse)
async def handle_sse(request: Request, tenant_id: str = Depends(get_tenant_id)):
    """
    Host AI connects to this endpoint to open the SSE stream.
    The Bearer token defines the tenant_id, which is locked into ContextVars.
    """
    logger.info(f"Opening MCP SSE stream for tenant: {tenant_id}")
    tenant_context.set(tenant_id)
    async with sse.connect_sse(request.scope, request.receive, request._send) as (read_stream, write_stream):
        await mcp_server.run(read_stream, write_stream, mcp_server.create_initialization_options())

@app.post("/messages")
async def handle_messages(request: Request, tenant_id: str = Depends(get_tenant_id)):
    """
    Host AI posts JSON-RPC messages here. 
    They are routed to the active SSE stream.
    """
    tenant_context.set(tenant_id)
    await sse.handle_post_message(request.scope, request.receive, request._send)

# ==========================================
# Stripe Webhook Layer
# ==========================================

def _verify_stripe_signature(payload: bytes, sig_header: str | None, webhook_secret: str) -> dict:
    if not sig_header:
        raise HTTPException(status_code=400, detail="Missing Stripe signature")
    try:
        return stripe.Webhook.construct_event(payload, sig_header, webhook_secret)
    except ValueError:
        logger.error("Invalid Stripe payload")
        raise HTTPException(status_code=400, detail="Invalid payload")
    except stripe.error.SignatureVerificationError:
        logger.error("Invalid Stripe signature")
        raise HTTPException(status_code=400, detail="Invalid signature")

def _activate_tenant_subscription(tenant_id: str | None, config):
    if not tenant_id:
        return
    try:
        supabase_client: Client = create_client(config.supabase_url, config.supabase_service_key)
        supabase_client.table("users").update({"is_subscribed": True}).eq("id", tenant_id).execute()
        logger.info(f"Database updated: user {tenant_id} is now subscribed.")
    except Exception as e:
        logger.error(f"Failed to update database for tenant {tenant_id}: {e}")

@app.post("/api/admin/stripe-webhook")
async def stripe_webhook(request: Request):
    """
    Receives payment success events from Stripe.
    """
    config = get_config()
    stripe.api_key = config.stripe_api_key

    payload = await request.body()
    sig_header = request.headers.get("stripe-signature")

    event = _verify_stripe_signature(payload, sig_header, config.stripe_webhook_secret)

    if event['type'] == 'checkout.session.completed':
        session = event['data']['object']
        tenant_id = session.get('client_reference_id')
        logger.info(f"💰 STRIPE PAYMENT RECEIVED for tenant: {tenant_id}! Activate their subscription.")
        _activate_tenant_subscription(tenant_id, config)
    else:
        logger.info(f"Unhandled Stripe event type: {event['type']}")

    return {"status": "success"}

