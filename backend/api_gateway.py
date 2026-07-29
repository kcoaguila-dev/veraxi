from fastapi import FastAPI, HTTPException, Depends, UploadFile, File, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from fastapi.responses import StreamingResponse
import logging
import json
import uuid
from backend.mcp_server.llm_loop import answer_question, stream_answer_question
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient
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
import asyncio
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

from contextlib import asynccontextmanager
from arq import create_pool
from arq.connections import RedisSettings

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    config = get_config()
    app.state.redis = await create_pool(RedisSettings.from_dsn(config.redis_url))
    yield
    # Shutdown
    await app.state.redis.close()

app = FastAPI(
    title="Veraxi Intelligence Engine", 
    description="Sovereign Hybrid GraphRAG & MCP Intelligence Platform",
    version="1.0.0",
    lifespan=lifespan
)

def get_auth_token_key(request: Request) -> str:
    auth = request.headers.get("Authorization")
    if auth and auth.startswith("Bearer "):
        return auth[7:]
    return get_remote_address(request)

limiter = Limiter(key_func=get_auth_token_key)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# Cross-Origin Resource Sharing (CORS) configured via environment variables
app.add_middleware(
    CORSMiddleware,
    allow_origins=config.cors_origins.split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

security = HTTPBearer(auto_error=False)

def _get_jwt_payload(token: str) -> dict:
    try:
        signing_key = jwks_client.get_signing_key_from_jwt(token)
        return jwt.decode(
            token, 
            signing_key.key, 
            algorithms=["RS256"],
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

def get_tenant_id(credentials: HTTPAuthorizationCredentials | None = Depends(security)) -> str:
    if not config.auth_enabled:
        return "local_personal_user"
    
    if not credentials:
        raise HTTPException(status_code=401, detail="Not authenticated")
        
    return _decode_and_validate_jwt(credentials.credentials)


class ChatRequest(BaseModel):
    question: str
    calculate_grounding: bool = False
    thread_id: str | None = None
    stream: bool = False
    is_temporary: bool = False
    # Optional per-request API key — overrides LLM_API_KEY in .env when provided
    api_key: str | None = None
    # Optional per-request model — overrides LLM_MODEL_NAME in .env when provided
    model: str | None = None


class ChatResponse(BaseModel):
    answer: str
    context: str | None = None
    grounding_score: float | None = None
    thread_id: str | None = None


class IngestRequest(BaseModel):
    text: str


async def _generate_and_save_title(question: str, tenant_id: str, thread_id: str, redis):
    try:
        from backend.mcp_server.llm_loop import answer_question
        prompt = f"Summarize this conversation starter into a concise 3-5 word title: {question}"
        answer, _ = await answer_question(
            prompt, 
            tenant_id=tenant_id, 
            thread_id=f"title_gen_{uuid.uuid4().hex[:8]}", 
            return_context=False, 
            is_temporary=True,
            model_override="gemini-3.5-flash"
        )
        title = answer.strip('"\'. \n')
        await redis.hset(f"tenant:{tenant_id}:thread_titles", thread_id, title)
    except Exception as e:
        logger.error(f"Error generating title for thread {thread_id}: {e}")

@app.post("/api/chat", response_model=ChatResponse)
@limiter.limit(config.rate_limit_chat)
async def chat_endpoint(request: Request, chat_request: ChatRequest, tenant_id: str = Depends(get_tenant_id)):
    logger.info(f"Received question: {chat_request.question} for tenant: {tenant_id}")
    if not chat_request.model:
        raise HTTPException(status_code=400, detail="No AI model selected")
        
    try:
        thread_id = chat_request.thread_id or str(uuid.uuid4())
        # Use per-request key if provided, fall back to server-side LLM_API_KEY env var
        api_key_override = chat_request.api_key or None
        
        # Track thread_id for this tenant if not temporary
        is_new_thread = False
        if not chat_request.is_temporary:
            added = await request.app.state.redis.sadd(f"tenant:{tenant_id}:threads", thread_id)
            if added == 1:
                is_new_thread = True
                asyncio.create_task(_generate_and_save_title(chat_request.question, tenant_id, thread_id, request.app.state.redis))
        
        if chat_request.stream:
            async def event_generator():
                try:
                    async for event in stream_answer_question(
                        chat_request.question, 
                        tenant_id=tenant_id,
                        thread_id=thread_id,
                        is_temporary=chat_request.is_temporary,
                        api_key_override=api_key_override,
                        model_override=chat_request.model,
                    ):
                        # Yield SSE formatted data
                        def custom_encoder(obj):
                            if hasattr(obj, 'model_dump'):
                                return obj.model_dump()
                            if hasattr(obj, 'dict'):
                                return obj.dict()
                            return str(obj)
                        yield f"data: {json.dumps(event, default=custom_encoder)}\n\n"
                    # Send a final 'done' event to signal stream completion
                    yield "data: [DONE]\n\n"
                except Exception as e:
                    import traceback
                    traceback.print_exc()
                    yield f"data: {json.dumps({'error': str(e)})}\n\n"
                    yield "data: [DONE]\n\n"
            
            return StreamingResponse(event_generator(), media_type="text/event-stream")
        
        # In a high-throughput production environment, we run this asynchronously
        answer, context = await answer_question(
            chat_request.question, 
            tenant_id=tenant_id, 
            thread_id=thread_id,
            return_context=True,
            is_temporary=chat_request.is_temporary,
            api_key_override=api_key_override,
            model_override=chat_request.model,
        )
        
        score = None
        if chat_request.calculate_grounding:
            from backend.evaluation.grounding import evaluate_groundedness
            score = evaluate_groundedness(answer, context)
            
        return ChatResponse(
            answer=answer, 
            context=context, 
            grounding_score=score,
            thread_id=thread_id
        )
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Error processing question: {e}")
        raise HTTPException(status_code=500, detail=str(e))

def _extract_messages_from_state(raw_messages: list, feedback_dict: dict = None) -> list:
    if feedback_dict is None:
        feedback_dict = {}
    messages_out = []
    for msg in raw_messages:
        msg_type = msg.__class__.__name__
        if msg_type in ["HumanMessage", "AIMessage"]:
            msg_id = getattr(msg, "id", None)
            if not msg_id:
                msg_id = getattr(msg, "additional_kwargs", {}).get("id") or str(id(msg))
            messages_out.append({
                "id": str(msg_id),
                "role": "user" if msg_type == "HumanMessage" else "assistant",
                "content": msg.content,
                "feedback": int(feedback_dict.get(str(msg_id), 0)),
                "model_name": getattr(msg, "additional_kwargs", {}).get("model_name")
            })
    return messages_out

@app.get("/api/chat/threads")
async def list_threads(request: Request, tenant_id: str = Depends(get_tenant_id)):
    """
    Returns a list of all thread IDs belonging to the tenant.
    """
    try:
        threads = await request.app.state.redis.smembers(f"tenant:{tenant_id}:threads")
        titles = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles")
        
        thread_list = []
        for t in threads:
            tid = t.decode("utf-8")
            title = titles.get(t, b"").decode("utf-8")
            if not title:
                title = "New Chat"
            thread_list.append({"thread_id": tid, "title": title})
            
        return {"threads": thread_list}
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Error listing threads: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/chat/threads/{thread_id}")
async def get_thread_history(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    """
    Returns the message history for a specific thread.
    """
    try:
        # Verify ownership
        is_owner = await request.app.state.redis.sismember(f"tenant:{tenant_id}:threads", thread_id)
        if not is_owner:
            raise HTTPException(status_code=403, detail="Thread not found or access denied.")
            
        from langgraph.checkpoint.redis.aio import AsyncRedisSaver
        
        config_obj = get_config()
        config = {"configurable": {"thread_id": thread_id}}
        
        async with AsyncRedisSaver.from_conn_string(config_obj.redis_url) as memory:
            state = await memory.aget_tuple(config)
            
        if not state:
            return {"messages": []}
            
        # Extract messages from the LangGraph state blob
        raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
        
        # Fetch feedbacks
        feedback_dict = {}
        try:
            feedbacks_raw = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:message_feedback")
            for k, v in feedbacks_raw.items():
                feedback_dict[k.decode("utf-8")] = int(v.decode("utf-8"))
        except Exception as e:
            logger.error(f"Failed to fetch feedback: {e}")
            pass

        messages_out = _extract_messages_from_state(raw_messages, feedback_dict)
                
        return {"messages": messages_out}
    except HTTPException:
        raise
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Error fetching thread {thread_id}: {e}")
        raise HTTPException(status_code=500, detail=str(e))


class VoiceListResponse(BaseModel):
    voices: list[dict[str, str]]

@app.get("/api/voices", response_model=VoiceListResponse)
async def get_voices():
    from backend.tts.voices import get_available_voices
    return {"voices": get_available_voices()}

class AudioRequest(BaseModel):
    text: str
    voice_id: str

@app.post("/api/chat/audio")
async def chat_audio(request: AudioRequest):
    from backend.tts.voices import get_voice
    from backend.tts.gpt_sovits_client import GPTSoVITSClient

    voice = get_voice(request.voice_id)
    if not voice:
        raise HTTPException(status_code=400, detail="Invalid voice ID")

    if not voice.get("ref_audio_path") or not voice.get("prompt_text"):
        # Could be default system voice or unconfigured voice
        raise HTTPException(status_code=400, detail="Voice not configured for backend synthesis")

    client = GPTSoVITSClient()
    try:
        audio_bytes = await client.synthesize(
            text=request.text,
            ref_audio_path=voice["ref_audio_path"],
            prompt_text=voice["prompt_text"],
            prompt_lang=voice.get("prompt_lang", "en"),
            text_lang=voice.get("text_lang", "en")
        )
        return StreamingResponse(
            iter([audio_bytes]),
            media_type="audio/wav",
            headers={"Content-Disposition": "attachment; filename=audio.wav"}
        )
    except Exception as e:
        logger.error(f"Failed to synthesize audio: {e}")
        raise HTTPException(status_code=500, detail="Failed to synthesize audio")
    finally:
        await client.close()

class FeedbackRequest(BaseModel):
    value: int # 1 for upvote, -1 for downvote, 0 to clear

@app.post("/api/chat/messages/{message_id}/feedback")
async def submit_feedback(message_id: str, payload: FeedbackRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
    try:
        if payload.value == 0:
            await request.app.state.redis.hdel(f"tenant:{tenant_id}:message_feedback", message_id)
        else:
            await request.app.state.redis.hset(f"tenant:{tenant_id}:message_feedback", message_id, payload.value)
        return {"status": "ok"}
    except Exception as e:
        logger.error(f"Error saving feedback: {e}")
        raise HTTPException(status_code=500, detail=str(e))



class EditRequest(BaseModel):
    content: str
    thread_id: str

@app.put("/api/chat/messages/{message_id}")
async def edit_message(message_id: str, payload: EditRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
    try:
        from langgraph.checkpoint.redis.aio import AsyncRedisSaver
        config_obj = get_config()
        config = {"configurable": {"thread_id": payload.thread_id}}
        
        async with AsyncRedisSaver.from_conn_string(config_obj.redis_url) as memory:
            state = await memory.aget_tuple(config)
            if not state:
                raise HTTPException(status_code=404, detail="Thread not found")
                
            raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
            target_msg = None
            for msg in raw_messages:
                msg_id = getattr(msg, "id", None) or getattr(msg, "additional_kwargs", {}).get("id") or str(id(msg))
                if str(msg_id) == message_id:
                    msg.content = payload.content
                    target_msg = msg
                    break
                    
            if target_msg:
                await memory.aupdate_state(config, {"messages": [target_msg]})
                
        return {"status": "ok"}
    except Exception as e:
        logger.error(f"Error editing message: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/chat/threads/{thread_id}/regenerate")
async def regenerate_response(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    # Placeholder for regenerating response. Usually involves removing last AI message and streaming again.
    # A full implementation requires deep LangGraph state manipulation.
    return {"status": "ok", "message": "Regenerate triggered (mock)"}

@app.get("/health")
async def health_check():
    return {"status": "ok"}





@app.get("/api/admin/stats")
def get_stats(tenant_id: str = Depends(get_tenant_id)):
    try:
        config = get_config()
        qdrant = QdrantStorageClient.from_config(config)
        neo4j = Neo4jStorageClient.from_config(config)

        stats = {}
        # Get Qdrant stats
        try:
            qdrant = QdrantStorageClient.from_config(config)
            from qdrant_client.http import models

            filter = models.Filter(must=[models.FieldCondition(key="tenant_id", match=models.MatchValue(value=tenant_id))])
            COLLECTION_NAME = config.qdrant_collection_name
            qdrant_points = qdrant.client.count(
                collection_name=COLLECTION_NAME, count_filter=filter
            )
            vector_count = qdrant_points.count
            stats["qdrant_points"] = vector_count
        except Exception as e:
            sentry_sdk.capture_exception(e)
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
            sentry_sdk.capture_exception(e)
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
        sentry_sdk.capture_exception(e)
        logger.error(f"Error getting stats: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/admin/ingest")
@limiter.limit(config.rate_limit_ingest)
async def ingest_data(request: Request, ingest_request: IngestRequest, tenant_id: str = Depends(get_tenant_id)):
    try:
        job = await request.app.state.redis.enqueue_job("process_ingestion_task", ingest_request.text, tenant_id)
        return {"status": "queued", "job_id": job.job_id}
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Error during ingestion: {e}")
        raise HTTPException(status_code=500, detail=str(e))


class SchemaDefinition(BaseModel):
    entities: list[str]
    relations: dict[str, dict[str, list[str]]]

@app.get("/api/admin/schema")
async def get_schema(request: Request, tenant_id: str = Depends(get_tenant_id)):
    schema = await request.app.state.redis.get(f"tenant:{tenant_id}:schema")
    if schema:
        return json.loads(schema)
    raise HTTPException(status_code=404, detail="No schema defined for this tenant.")

@app.post("/api/admin/schema")
async def set_schema(request: Request, schema: SchemaDefinition, tenant_id: str = Depends(get_tenant_id)):
    await request.app.state.redis.set(f"tenant:{tenant_id}:schema", schema.model_dump_json())
    return {"status": "success"}

class AutoGenerateSchemaRequest(BaseModel):
    description: str
    temperature: float = 0.3
    max_entities: int = 6
    max_relations: int = 10

@app.post("/api/admin/schema/auto-generate")
async def auto_generate_schema(data: AutoGenerateSchemaRequest):
    config = get_config()
    from openai import AsyncOpenAI
    from backend.prompts import get_auto_ontology_prompt
    
    client = AsyncOpenAI(**config.get_llm_client_args())
    try:
        prompt = get_auto_ontology_prompt(data.max_entities, data.max_relations)
        response = await client.chat.completions.create(
            model=config.llm_model_name,
            messages=[
                {"role": "system", "content": prompt},
                {"role": "user", "content": data.description}
            ],
            response_format={"type": "json_object"},
            temperature=data.temperature
        )
        content = response.choices[0].message.content
        schema = json.loads(content)
        return schema
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to generate valid schema: {str(e)}")

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

        logger.info(f"Enqueueing {len(markdown_text)} bytes of markdown from {file.filename}")
        job = await request.app.state.redis.enqueue_job("process_ingestion_task", markdown_text, tenant_id)
        return {"status": "queued", "job_id": job.job_id}
    except HTTPException:
        raise
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Error during file ingestion: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/admin/ingest/url")
@limiter.limit(config.rate_limit_ingest)
async def ingest_url(request: Request, url_request: UrlIngestRequest, tenant_id: str = Depends(get_tenant_id)):
    try:
        config = get_config()
        logger.info(f"Converting URL {url_request.url} with Docling...")
        converter = DocumentConverter()
        result = converter.convert(url_request.url)
        markdown_text = result.document.export_to_markdown()

        logger.info(f"Enqueueing {len(markdown_text)} bytes of markdown from {url_request.url}")
        job = await request.app.state.redis.enqueue_job("process_ingestion_task", markdown_text, tenant_id)
        return {"status": "queued", "job_id": job.job_id}
    except Exception as e:
        sentry_sdk.capture_exception(e)
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
        sentry_sdk.capture_exception(e)
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

