import asyncio
import json
import logging
import os
import tempfile
import uuid

import httpx
import jwt
import magic
import sentry_sdk
import stripe
from backend import context as byod_context
from backend.config import get_config
from backend.mcp_server.context import tenant_context
from backend.mcp_server.llm_loop import (
    answer_question,
    generate_chat_title,
    stream_answer_question,
)
from backend.mcp_server.server import mcp_server
from backend.models_config import DEFAULT_PROVIDER_MODELS
from backend.security.moderation import moderate_text
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient
from docling.document_converter import DocumentConverter
from fastapi import Depends, FastAPI, File, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient
from mcp.server.sse import SseServerTransport
from pydantic import BaseModel
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from supabase import Client, create_client

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

from sentry_sdk.integrations.fastapi import FastApiIntegration

config = get_config()
if config.sentry_dsn:
    sentry_sdk.init(
        dsn=config.sentry_dsn,
        traces_sample_rate=1.0,
        profiles_sample_rate=1.0,
        integrations=[FastApiIntegration()],
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

import sys

test_storage = "memory://" if "pytest" in sys.modules else config.redis_url
limiter = Limiter(key_func=get_auth_token_key, storage_uri=test_storage)
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

@app.middleware("http")
async def byod_context_middleware(request: Request, call_next):
    # Extract BYOD headers and set them in ContextVars for this request
    byod_context.request_neo4j_uri.set(request.headers.get("x-byod-neo4j-uri"))
    byod_context.request_neo4j_user.set(request.headers.get("x-byod-neo4j-user"))
    byod_context.request_neo4j_pass.set(request.headers.get("x-byod-neo4j-pass"))
    byod_context.request_qdrant_url.set(request.headers.get("x-byod-qdrant-url"))
    byod_context.request_qdrant_key.set(request.headers.get("x-byod-qdrant-key"))
    
    response = await call_next(request)
    return response

security = HTTPBearer(auto_error=False)

def _get_jwt_payload(token: str) -> dict:
    try:
        signing_key = jwks_client.get_signing_key_from_jwt(token)
        return jwt.decode(
            token, 
            signing_key.key, 
            algorithms=["RS256", "ES256", "HS256"],
            audience="authenticated"
        )
    except jwt.ExpiredSignatureError as e:
        logger.warning(f"JWT Expired: {e}")
        raise HTTPException(status_code=401, detail="Token has expired")
    except jwt.InvalidAudienceError as e:
        logger.warning(f"JWT Invalid Audience: {e}")
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

from backend.security.api_keys import generate_api_key, resolve_api_key

# Lazy Supabase service-role client — used for API key lookups.
# Initialized once at first use to avoid startup overhead.
_supabase_client: "Client | None" = None

def _get_supabase() -> "Client":
    """Return a cached Supabase service-role client."""
    global _supabase_client
    if _supabase_client is None:
        _supabase_client = create_client(config.supabase_url, config.supabase_service_key)
    return _supabase_client

def get_tenant_id(credentials: HTTPAuthorizationCredentials | None = Depends(security)) -> str:  # noqa: B008
    if not config.auth_enabled:
        return "local_personal_user"

    if not credentials:
        logger.warning("No credentials provided in request headers (Authorization header missing or invalid)")
        raise HTTPException(status_code=401, detail="Not authenticated")

    token = credentials.credentials

    # Fast path: personal API key (vx- prefix). No JWT decode needed.
    if token.startswith("vx-"):
        return resolve_api_key(token, _get_supabase())

    # Default path: Supabase JWT
    return _decode_and_validate_jwt(token)


async def verify_infrastructure_access(request: Request, tenant_id: str = Depends(get_tenant_id)) -> str:
    if not config.is_enterprise or not config.auth_enabled:
        return tenant_id
        
    # Check BYOD headers (must have both Neo4j and Qdrant)
    uri = byod_context.request_neo4j_uri.get()
    qdrant = byod_context.request_qdrant_url.get()
    
    if uri and qdrant:
        return tenant_id
        
    # Check cache
    cache_key = f"tenant:{tenant_id}:subscription_status"
    cached = await request.app.state.redis.get(cache_key)
    if cached is not None:
        is_subscribed = cached.decode("utf-8") == "true"
    else:
        # Fetch and cache
        import asyncio
        def _fetch_sub():
            try:
                res = _get_supabase().table("users").select("is_subscribed").eq("id", tenant_id).execute()
                if res.data and len(res.data) > 0:
                    return bool(res.data[0].get("is_subscribed", False))
            except Exception as e:  # noqa: BLE001
                logger.error(f"Failed to check subscription status: {e}")
            return False
            
        is_subscribed = await asyncio.to_thread(_fetch_sub)
        await request.app.state.redis.setex(cache_key, 86400, "true" if is_subscribed else "false")
        
    if is_subscribed:
        return tenant_id
        
    raise HTTPException(
        status_code=402, 
        detail="Payment Required: Free tier users must configure Bring Your Own Database (BYOD) infrastructure in Settings."
    )



class ChatRequest(BaseModel):
    question: str
    calculate_grounding: bool = False
    thread_id: str | None = None
    stream: bool = False
    is_temporary: bool = False
    # Optional per-request API key — overrides LLM_API_KEY in .env when provided
    api_key: str | None = None
    # Optional per-request base URL — overrides default LangChain URLs
    base_url: str | None = None
    # Optional per-request model — overrides LLM_MODEL_NAME in .env when provided
    model: str | None = None
    # Optional tool settings override from UI
    tool_settings: dict | None = None


class ChatResponse(BaseModel):
    answer: str
    context: str | None = None
    grounding_score: float | None = None
    metrics: dict[str, float | str | None] | None = None
    thread_id: str | None = None


class IngestRequest(BaseModel):
    text: str
    fast_extraction: bool = False
    language: str = "en"
    custom_stop_words: list[str] = []


async def _generate_and_save_title(question: str, tenant_id: str, thread_id: str, redis, api_key_override: str | None = None, base_url_override: str | None = None, model_override: str | None = None):
    try:
        title = await generate_chat_title(
            question,
            api_key_override=api_key_override,
            base_url_override=base_url_override,
            model_override=model_override,
        )
        if not title:
            return None
        await redis.hset(f"tenant:{tenant_id}:thread_titles", thread_id, title)
        return title
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error generating title for thread {thread_id}: {e}")
        return None

class CheckoutSessionRequest(BaseModel):
    plan: str

@app.post("/api/v1/payments/create-checkout-session")
async def create_checkout_session(request: CheckoutSessionRequest, tenant_id: str = Depends(get_tenant_id)):
    if not config.stripe_api_key:
        raise HTTPException(status_code=500, detail="Stripe is not configured on this server.")
    
    stripe.api_key = config.stripe_api_key
    
    try:
        # In a real app, these would map to actual Stripe Price IDs created in the dashboard.
        # For this implementation, we will use price_data for dynamic pricing creation.
        unit_amount = 19000 if request.plan == 'annual' else 1900
        plan_name = "Veraxi Pro Annual" if request.plan == 'annual' else "Veraxi Pro Monthly"
        
        session = stripe.checkout.Session.create(
            payment_method_types=['card'],
            line_items=[{
                'price_data': {
                    'currency': 'usd',
                    'product_data': {
                        'name': plan_name,
                    },
                    'unit_amount': unit_amount,
                },
                'quantity': 1,
            }],
            mode='payment',
            success_url="https://veraxi.me/#/admin?success=true",
            cancel_url="https://veraxi.me/#/admin?canceled=true",
            client_reference_id=tenant_id,
        )
        return {"checkout_url": session.url}
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Stripe error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/chat", response_model=ChatResponse)
@limiter.limit(config.rate_limit_chat)
async def chat_endpoint(request: Request, chat_request: ChatRequest, tenant_id: str = Depends(verify_infrastructure_access)):
    logger.warning(f"Received question: {chat_request.question} for tenant: {tenant_id} | tool_settings: {chat_request.tool_settings}")
    if not chat_request.model:
        raise HTTPException(status_code=400, detail="No AI model selected")
        
    # Content Moderation Intercept
    api_key_override = chat_request.api_key or None
    is_flagged = await moderate_text(chat_request.question, api_key=api_key_override)
    if is_flagged:
        raise HTTPException(status_code=400, detail="Message flagged by content moderation policy.")
        
    try:
        thread_id = chat_request.thread_id or str(uuid.uuid4())
        
        title_task = None
        # Track thread_id for this tenant if not temporary
        if not chat_request.is_temporary:
            added = await request.app.state.redis.sadd(f"tenant:{tenant_id}:threads", thread_id)
            
            import time
            await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_timestamps", thread_id, str(time.time()))
            
            if added == 1:
                # Immediately set a rudimentary title based on the user's query so the UI shows something
                initial_title = chat_request.question[:40] + "..." if len(chat_request.question) > 40 else chat_request.question
                await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_titles", thread_id, initial_title)
                
                title_task = asyncio.create_task(_generate_and_save_title(
                    chat_request.question, 
                    tenant_id, 
                    thread_id, 
                    request.app.state.redis,
                    api_key_override=api_key_override,
                    base_url_override=chat_request.base_url,
                    model_override=chat_request.model
                ))
        
        if chat_request.stream:
            async def event_generator():
                try:
                    # Inject a metadata event so the client knows the thread_id
                    yield f"data: {json.dumps({'event': 'metadata', 'data': {'thread_id': thread_id}})}\n\n"
                    
                    async for event in stream_answer_question(
                        chat_request.question, 
                        tenant_id=tenant_id,
                        thread_id=thread_id,
                        is_temporary=chat_request.is_temporary,
                        api_key_override=api_key_override,
                        base_url_override=chat_request.base_url,
                        model_override=chat_request.model,
                        calculate_grounding=chat_request.calculate_grounding,
                        tool_settings=chat_request.tool_settings,
                    ):
                        # Yield SSE formatted data
                        def custom_encoder(obj):
                            if hasattr(obj, 'model_dump'):
                                return obj.model_dump()
                            if hasattr(obj, 'dict'):
                                return obj.dict()
                            return str(obj)
                        yield f"data: {json.dumps(event, default=custom_encoder)}\n\n"
                        
                    if title_task:
                        try:
                            # Give it a bit of time to finish
                            title = await asyncio.wait_for(title_task, timeout=10.0)
                            if title:
                                yield f"data: {json.dumps({'event': 'metadata', 'data': {'thread_title': title}})}\n\n"
                        except Exception as e:  # noqa: BLE001
                            logger.error(f"Error waiting for title task: {e}")
                            
                    # Send a final 'done' event to signal stream completion
                    yield "data: [DONE]\n\n"
                except Exception as e:  # noqa: BLE001
                    sentry_sdk.capture_exception(e)
                    logger.error(f"Error in title generation task: {e}")
                    yield f"data: {json.dumps({'error': str(e)})}\n\n"
                    yield "data: [DONE]\n\n"
            
            return StreamingResponse(event_generator(), media_type="text/event-stream")
        
        # In a high-throughput production environment, we run this asynchronously
        answer, context, metrics = await answer_question(
            chat_request.question, 
            tenant_id=tenant_id, 
            thread_id=thread_id,
            return_context=True,
            return_metrics=True,
            is_temporary=chat_request.is_temporary,
            api_key_override=api_key_override,
            base_url_override=chat_request.base_url,
            model_override=chat_request.model,
            calculate_grounding=chat_request.calculate_grounding,
            tool_settings=chat_request.tool_settings,
        )
            
        return ChatResponse(
            answer=answer, 
            context=context, 
            grounding_score=metrics.get("grounding_score") if metrics else None,
            metrics=metrics or None,
            thread_id=thread_id
        )
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error processing question: {e}")
        raise HTTPException(status_code=500, detail=str(e))

def _process_single_message(msg, tool_results, feedback_dict):
    msg_type = msg.__class__.__name__
    if msg_type not in ["HumanMessage", "AIMessage"]:
        return None
        
    # Filter out legacy system-injected messages that were saved as HumanMessages
    if msg_type == "HumanMessage" and msg.content:
        content_str = str(msg.content)
        if content_str.startswith(("Here is the context retrieved from the database:", "Web Search Fallback Context:")):
            return None
            
    msg_id = getattr(msg, "id", None)
    if not msg_id:
        msg_id = getattr(msg, "additional_kwargs", {}).get("id") or str(id(msg))
    metrics = getattr(msg, "additional_kwargs", {}).get("metrics")
    
    tool_events = []
    if hasattr(msg, "tool_calls") and msg.tool_calls:
        for tc in msg.tool_calls:
            tool_events.append({
                "id": tc.get("id", ""),
                "name": tc.get("name", "tool"),
                "args": tc.get("args", {}),
                "result": tool_results.get(tc.get("id"), ""),
                "isComplete": True
            })
            
    return {
        "id": str(msg_id),
        "role": "user" if msg_type == "HumanMessage" else "assistant",
        "content": msg.content,
        "feedback": int(feedback_dict.get(str(msg_id), 0)),
        "model_name": getattr(msg, "additional_kwargs", {}).get("model_name"),
        "metrics": metrics if isinstance(metrics, dict) else None,
        "toolEvents": tool_events,
    }

def _extract_messages_from_state(raw_messages: list, feedback_dict: dict | None = None) -> list:
    if feedback_dict is None:
        feedback_dict = {}
        
    tool_results = {}
    for msg in raw_messages:
        if getattr(msg, "type", "") == "tool" or msg.__class__.__name__ == "ToolMessage":
            tool_results[msg.tool_call_id] = msg.content
            
    messages_out = []
    for msg in raw_messages:
        processed = _process_single_message(msg, tool_results, feedback_dict)
        if processed:
            messages_out.append(processed)
    return messages_out

@app.get("/api/chat/threads")
async def list_threads(request: Request, tenant_id: str = Depends(get_tenant_id)):
    logger.info(f"LIST THREADS CALLED FOR TENANT: {tenant_id}")
    """
    Returns a list of all thread IDs belonging to the tenant.
    """
    try:
        threads = await request.app.state.redis.smembers(f"tenant:{tenant_id}:threads")
        titles = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles")
        pinned = await request.app.state.redis.smembers(f"tenant:{tenant_id}:pinned_threads")
        archived = await request.app.state.redis.smembers(f"tenant:{tenant_id}:archived_threads")
        projects = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_projects")
        timestamps = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_timestamps")
        
        thread_list = []
        for t in threads:
            tid = t.decode("utf-8")
            title = titles.get(t, b"").decode("utf-8")
            if not title:
                title = "New Chat"
            is_pinned = t in pinned
            is_archived = t in archived
            project_id = projects.get(t, b"").decode("utf-8")
            
            # Use timestamp if available, otherwise 0 for older threads
            try:
                ts = float(timestamps.get(t, b"0").decode("utf-8"))
            except ValueError:
                ts = 0.0
                
            thread_list.append({
                "thread_id": tid, 
                "title": title,
                "is_pinned": is_pinned,
                "is_archived": is_archived,
                "project_id": project_id if project_id else None,
                "_timestamp": ts
            })
            
        # Sort by timestamp descending (newest first)
        thread_list.sort(key=lambda x: x["_timestamp"], reverse=True)
        # Remove the internal timestamp field before returning to save bandwidth (or keep it if useful)
        for t in thread_list:
            del t["_timestamp"]
            
        return {"threads": thread_list}
    except Exception as e:  # noqa: BLE001
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
            
        from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
        
        config_obj = get_config()
        config = {"configurable": {"thread_id": thread_id}}
        
        async with AsyncPostgresSaver.from_conn_string(config_obj.postgres_url) as memory:
            await memory.setup()
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
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Failed to fetch feedback: {e}")

        messages_out = _extract_messages_from_state(raw_messages, feedback_dict)
                
        return {"messages": messages_out}
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error fetching thread {thread_id}: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/chat/threads/{thread_id}/share")
async def share_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    """
    Marks a thread as public, allowing anyone with the link to view it.
    """
    try:
        # Verify ownership
        is_owner = await request.app.state.redis.sismember(f"tenant:{tenant_id}:threads", thread_id)
        if not is_owner:
            raise HTTPException(status_code=403, detail="Thread not found or access denied.")
            
        await request.app.state.redis.set(f"shared_thread:{thread_id}", "true")
        return {"success": True, "share_id": thread_id}
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/shared/threads/{thread_id}")
async def get_shared_thread_history(thread_id: str, request: Request):
    """
    Returns the message history for a public thread. No auth required.
    """
    try:
        # Check if it is shared
        is_shared = await request.app.state.redis.get(f"shared_thread:{thread_id}")
        if not is_shared:
            raise HTTPException(status_code=404, detail="Shared thread not found.")
            
        from langgraph.checkpoint.redis.aio import AsyncRedisSaver
        
        config_obj = get_config()
        config = {"configurable": {"thread_id": thread_id}}
        
        async with AsyncRedisSaver.from_conn_string(config_obj.redis_url) as memory:
            state = await memory.aget_tuple(config)
            
        if not state:
            return {"messages": []}
            
        raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
        
        # Don't show personal feedbacks to public users
        feedback_dict = {}

        messages_out = _extract_messages_from_state(raw_messages, feedback_dict)
                
        return {"messages": messages_out}
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error fetching shared thread {thread_id}: {e}")
        raise HTTPException(status_code=500, detail=str(e))




class VoiceListResponse(BaseModel):
    voices: list[dict]

class VoiceSaveRequest(BaseModel):
    voices: list[dict]

@app.get("/api/voices", response_model=VoiceListResponse)
async def get_voices(gpt_sovits_url: str | None = None):
    from backend.tts.gpt_sovits_client import GPTSoVITSClient
    from backend.tts.voices import get_all_voices

    if gpt_sovits_url:
        client = GPTSoVITSClient(base_url=gpt_sovits_url)
        try:
            await client.check_connection()
        except Exception as e:  # noqa: BLE001
            raise HTTPException(status_code=503, detail=f"GPT-SoVITS instance unreachable: {str(e)}")
        finally:
            await client.close()

    return {"voices": get_all_voices()}

@app.post("/api/voices", response_model=VoiceListResponse)
async def save_voices(request: VoiceSaveRequest):
    from backend.tts.voices import get_all_voices
    from backend.tts.voices import save_voices as save_voices_to_disk
    
    try:
        save_voices_to_disk(request.voices)
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        raise HTTPException(status_code=500, detail=str(e))
        
    return {"voices": get_all_voices()}

import shutil

from fastapi import Form


@app.post("/api/voices/upload", response_model=VoiceListResponse)
async def upload_voice(
    name: str = Form(...),
    prompt_text: str = Form(...),
    file: UploadFile = File(...)  # noqa: B008
):
    from backend.tts.voices import add_voice, get_all_voices
    
    try:
        # Save file to backend/tts/voices/
        voices_dir = os.path.join(os.path.dirname(__file__), "tts", "voices")
        os.makedirs(voices_dir, exist_ok=True)
        
        # Use original filename or generate a safe one
        safe_filename = file.filename.replace(" ", "_")
        file_path = os.path.join(voices_dir, safe_filename)
        
        with open(file_path, "wb") as buffer:  # noqa: ASYNC230
            shutil.copyfileobj(file.file, buffer)
            
        voice_id = safe_filename.rsplit(".", 1)[0].lower()
        ref_audio_path = f"voices/{safe_filename}"
        
        add_voice(
            voice_id=voice_id,
            name=name,
            ref_audio_path=ref_audio_path,
            prompt_text=prompt_text
        )
        
        return {"voices": get_all_voices()}
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error uploading voice: {e}")
        raise HTTPException(status_code=500, detail=str(e))

class AudioRequest(BaseModel):
    text: str
    voice_id: str
    message_id: str | None = None

@app.get("/api/chat/audio/{message_id}")
async def get_audio(message_id: str):
    from fastapi.responses import FileResponse
    cache_dir = os.path.join(os.path.dirname(__file__), "tts", "cache")
    cached_file_path = os.path.join(cache_dir, f"{message_id}.wav")
    if os.path.exists(cached_file_path):
        return FileResponse(cached_file_path, media_type="audio/wav", filename="audio.wav")
    raise HTTPException(status_code=404, detail="Audio not found")

@app.post("/api/chat/audio")
async def chat_audio(request: AudioRequest, req: Request):
    from backend.tts.gpt_sovits_client import GPTSoVITSClient
    from backend.tts.voices import get_voice
    from fastapi.responses import FileResponse

    # 1. Check Cache first
    if request.message_id:
        cache_dir = os.path.join(os.path.dirname(__file__), "tts", "cache")
        os.makedirs(cache_dir, exist_ok=True)
        cached_file_path = os.path.join(cache_dir, f"{request.message_id}.wav")
        if os.path.exists(cached_file_path):
            logger.info(f"Returning cached audio for message {request.message_id}")
            return FileResponse(cached_file_path, media_type="audio/wav", filename="audio.wav")

    voice = get_voice(request.voice_id)
    logger.info(f"chat_audio called with voice_id: {request.voice_id}")
    if not voice:
        logger.error(f"Invalid voice ID: {request.voice_id}")
        raise HTTPException(status_code=400, detail="Invalid voice ID")

    if not voice.get("ref_audio_path") or not voice.get("prompt_text"):
        # Could be default system voice or unconfigured voice
        logger.error(f"Voice not configured for backend synthesis. Voice data: {voice}")
        raise HTTPException(status_code=400, detail="Voice not configured for backend synthesis")

    gpt_sovits_url = req.headers.get("x-gpt-sovits-url")
    client = GPTSoVITSClient(base_url=gpt_sovits_url)
    try:
        audio_bytes = await client.synthesize(
            text=request.text,
            ref_audio_path=voice["ref_audio_path"],
            prompt_text=voice["prompt_text"],
            prompt_lang=voice.get("prompt_lang", "en"),
            text_lang=voice.get("text_lang", "en")
        )

        # 2. Save to Cache
        if request.message_id:
            cache_dir = os.path.join(os.path.dirname(__file__), "tts", "cache")
            os.makedirs(cache_dir, exist_ok=True)
            cached_file_path = os.path.join(cache_dir, f"{request.message_id}.wav")
            import asyncio
            from pathlib import Path
            await asyncio.to_thread(Path(cached_file_path).write_bytes, audio_bytes)
            
            # 3. Cleanup old cache
            from backend.tts.cache_manager import cleanup_audio_cache
            cleanup_audio_cache(cache_dir, max_files=100, max_age_hours=24)

            return FileResponse(cached_file_path, media_type="audio/wav", filename="audio.wav")
            
        return StreamingResponse(
            iter([audio_bytes]),
            media_type="audio/wav",
            headers={"Content-Disposition": "attachment; filename=audio.wav"}
        )
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Failed to synthesize audio: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to synthesize audio: {e!s}")
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
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
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
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error editing message: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/chat/threads/{thread_id}/regenerate")
async def regenerate_response(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    # Placeholder for regenerating response. Usually involves removing last AI message and streaming again.
    # A full implementation requires deep LangGraph state manipulation.
    return {"status": "ok", "message": "Regenerate triggered (mock)"}

class TitleRequest(BaseModel):
    title: str

@app.put("/api/chat/threads/{thread_id}/title")
async def rename_thread(thread_id: str, payload: TitleRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
    await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_titles", thread_id, payload.title)
    return {"status": "ok"}

@app.post("/api/chat/threads/{thread_id}/pin")
async def toggle_pin_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    is_pinned = await request.app.state.redis.sismember(f"tenant:{tenant_id}:pinned_threads", thread_id)
    if is_pinned:
        await request.app.state.redis.srem(f"tenant:{tenant_id}:pinned_threads", thread_id)
        return {"status": "unpinned"}
    else:
        await request.app.state.redis.sadd(f"tenant:{tenant_id}:pinned_threads", thread_id)
        return {"status": "pinned"}

@app.post("/api/chat/threads/{thread_id}/archive")
async def toggle_archive_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    is_archived = await request.app.state.redis.sismember(f"tenant:{tenant_id}:archived_threads", thread_id)
    if is_archived:
        await request.app.state.redis.srem(f"tenant:{tenant_id}:archived_threads", thread_id)
        return {"status": "unarchived"}
    else:
        await request.app.state.redis.sadd(f"tenant:{tenant_id}:archived_threads", thread_id)
        return {"status": "archived"}

@app.delete("/api/chat/threads/{thread_id}")
async def delete_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    await request.app.state.redis.srem(f"tenant:{tenant_id}:threads", thread_id)
    await request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_titles", thread_id)
    await request.app.state.redis.srem(f"tenant:{tenant_id}:pinned_threads", thread_id)
    await request.app.state.redis.srem(f"tenant:{tenant_id}:archived_threads", thread_id)
    await request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_projects", thread_id)
    return {"status": "deleted"}

@app.delete("/api/chat/threads")
async def delete_all_threads(request: Request, tenant_id: str = Depends(get_tenant_id)):
    await request.app.state.redis.delete(f"tenant:{tenant_id}:threads")
    await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_titles")
    await request.app.state.redis.delete(f"tenant:{tenant_id}:pinned_threads")
    await request.app.state.redis.delete(f"tenant:{tenant_id}:archived_threads")
    await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_projects")
    return {"status": "all_deleted"}

@app.post("/api/chat/threads/{thread_id}/duplicate")
async def duplicate_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    new_thread_id = str(uuid.uuid4())
    titles = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles")
    old_title = titles.get(thread_id.encode(), b"").decode("utf-8")
    new_title = f"{old_title} (Copy)" if old_title else "New Chat (Copy)"
    await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_titles", new_thread_id, new_title)
    await request.app.state.redis.sadd(f"tenant:{tenant_id}:threads", new_thread_id)

    try:
        from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
        config_obj = get_config()
        old_config = {"configurable": {"thread_id": thread_id}}
        new_config = {"configurable": {"thread_id": new_thread_id}}
        
        async with AsyncPostgresSaver.from_conn_string(config_obj.postgres_url) as memory:
            await memory.setup()
            state = await memory.aget_tuple(old_config)
            if state:
                raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
                if raw_messages:
                    import copy
                    copied_messages = copy.deepcopy(raw_messages)
                    for msg in copied_messages:
                        msg.id = str(uuid.uuid4())
                        if hasattr(msg, "additional_kwargs") and "id" in msg.additional_kwargs:
                            msg.additional_kwargs["id"] = msg.id
                    await memory.aupdate_state(new_config, {"messages": copied_messages})
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error duplicating LangGraph state: {e}")
        
    return {"status": "ok", "new_thread_id": new_thread_id}

@app.post("/api/chat/threads/{thread_id}/share")
async def share_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):  # noqa: F811
    is_owner = await request.app.state.redis.sismember(f"tenant:{tenant_id}:threads", thread_id)
    if not is_owner:
        raise HTTPException(status_code=403, detail="Access denied")
    
    try:
        from langgraph.checkpoint.redis.aio import AsyncRedisSaver
        config_obj = get_config()
        config = {"configurable": {"thread_id": thread_id}}
        async with AsyncRedisSaver.from_conn_string(config_obj.redis_url) as memory:
            state = await memory.aget_tuple(config)
            
        messages_out = []
        if state:
            raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
            messages_out = _extract_messages_from_state(raw_messages)
            
        share_id = str(uuid.uuid4())
        
        titles = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles")
        title = titles.get(thread_id.encode(), b"").decode("utf-8")
        
        share_data = {
            "title": title or "Shared Chat",
            "messages": messages_out
        }
        await request.app.state.redis.set(f"share:{share_id}", json.dumps(share_data))
        await request.app.state.redis.expire(f"share:{share_id}", 30 * 24 * 60 * 60)
        
        return {"share_id": share_id}
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error sharing thread: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/share/{share_id}")
async def get_shared_thread(share_id: str, request: Request):
    data = await request.app.state.redis.get(f"share:{share_id}")
    if not data:
        raise HTTPException(status_code=404, detail="Shared link not found or expired")
    return json.loads(data)
@app.post("/api/chat/upload_attachment")
async def upload_attachment(request: Request, file: UploadFile = File(...), tenant_id: str = Depends(get_tenant_id)):  # noqa: B008
    try:
        # Create uploads directory if not exists
        os.makedirs("uploads", exist_ok=True)
        file_id = str(uuid.uuid4())
        _, file_extension = os.path.splitext(file.filename)
        file_path = os.path.join("uploads", f"{file_id}{file_extension}")
        
        content = await file.read()
        with open(file_path, "wb") as f:  # noqa: ASYNC230
            f.write(content)
            
        file_size = len(content)
        
        # Metadata
        import time
        file_metadata = {
            "id": file_id,
            "filename": file.filename,
            "size": file_size,
            "date": int(time.time()),
            "path": file_path
        }
        
        await request.app.state.redis.hset(f"tenant:{tenant_id}:files", file_id, json.dumps(file_metadata))
        
        # Extract text for chat context
        mime_type = magic.from_file(file_path, mime=True)
        extracted_text = f"File {file.filename} uploaded."
        
        # For simplicity in chat attachments, we can try to extract text using Docling or just return simple text
        if mime_type.startswith("text/") or mime_type in ["application/json", "application/csv"]:
            try:
                extracted_text = content.decode("utf-8")
            except:  # noqa: E722, S110
                pass
        else:
            try:
                converter = DocumentConverter()
                result = converter.convert(file_path)
                extracted_text = result.document.export_to_markdown()
            except Exception as e:  # noqa: BLE001
                logger.warning(f"Docling could not convert {file.filename}: {e}")
        
        return {"text": extracted_text, "file_id": file_id}
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error uploading attachment: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/chat/files")
async def get_files(request: Request, tenant_id: str = Depends(get_tenant_id)):
    try:
        files_dict = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:files")
        files_list = []
        for fmeta in files_dict.values():
            files_list.append(json.loads(fmeta.decode("utf-8")))
        return {"files": files_list}
    except Exception as e:  # noqa: BLE001
        logger.error(f"Error getting files: {e}")
        return {"files": []}

@app.delete("/api/chat/files/{file_id}")
async def delete_file(file_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    try:
        file_meta_raw = await request.app.state.redis.hget(f"tenant:{tenant_id}:files", file_id)
        if file_meta_raw:
            file_meta = json.loads(file_meta_raw.decode("utf-8"))
            if "path" in file_meta and os.path.exists(file_meta["path"]):
                os.remove(file_meta["path"])
            await request.app.state.redis.hdel(f"tenant:{tenant_id}:files", file_id)
        return {"success": True}
    except Exception as e:  # noqa: BLE001
        logger.error(f"Error deleting file: {e}")
        raise HTTPException(status_code=500, detail=str(e))

class ProjectCreateRequest(BaseModel):
    name: str
    
class ProjectRenameRequest(BaseModel):
    name: str
    
class ProjectAssignRequest(BaseModel):
    project_id: str

@app.get("/api/projects")
async def list_projects(request: Request, tenant_id: str = Depends(get_tenant_id)):
    projects_dict = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:projects")
    projects_list = []
    for pid, pname in projects_dict.items():
        projects_list.append({"id": pid.decode("utf-8"), "name": pname.decode("utf-8")})
    return {"projects": projects_list}

@app.post("/api/projects")
async def create_project(payload: ProjectCreateRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
    project_id = str(uuid.uuid4())
    await request.app.state.redis.hset(f"tenant:{tenant_id}:projects", project_id, payload.name)
    return {"id": project_id, "name": payload.name}

@app.put("/api/projects/{project_id}")
async def rename_project(project_id: str, payload: ProjectRenameRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
    project_exists = await request.app.state.redis.hexists(f"tenant:{tenant_id}:projects", project_id)
    if not project_exists:
        raise HTTPException(status_code=404, detail="Project not found")
    await request.app.state.redis.hset(f"tenant:{tenant_id}:projects", project_id, payload.name)
    return {"status": "ok"}

@app.delete("/api/projects/{project_id}")
async def delete_project(project_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
    project_exists = await request.app.state.redis.hexists(f"tenant:{tenant_id}:projects", project_id)
    if not project_exists:
        raise HTTPException(status_code=404, detail="Project not found")
        
    await request.app.state.redis.hdel(f"tenant:{tenant_id}:projects", project_id)
    
    # Unassign threads that belonged to this project
    thread_projects = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_projects")
    for tid, pid in thread_projects.items():
        if pid.decode("utf-8") == project_id:
            await request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_projects", tid.decode("utf-8"))
            
    return {"status": "ok"}

@app.post("/api/chat/threads/{thread_id}/project")
async def assign_project(thread_id: str, payload: ProjectAssignRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
    if not payload.project_id:
        await request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_projects", thread_id)
    else:
        project_exists = await request.app.state.redis.hexists(f"tenant:{tenant_id}:projects", payload.project_id)
        if not project_exists:
            raise HTTPException(status_code=404, detail="Project not found")
        await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_projects", thread_id, payload.project_id)
    return {"status": "ok"}

@app.get("/api/config/ui")
async def get_ui_config(request: Request):
    """
    Returns UI configuration URLs for the frontend.
    """
    config = get_config()
    return {
        "help_faq_url": config.help_faq_url,
        "terms_of_service_url": config.terms_of_service_url,
        "privacy_policy_url": config.privacy_policy_url,
    }

@app.get("/health")
async def health_check():
    return {"status": "ok"}


# ==========================================
# Personal API Key Management
# ==========================================

class ApiKeyCreateRequest(BaseModel):
    name: str
    expires_at: str | None = None  # ISO-8601 string; None = permanent

@app.get("/api/user/api-keys")
async def list_api_keys(tenant_id: str = Depends(get_tenant_id)):
    """List all API keys for the current tenant (names, prefixes, dates — never hashes)."""
    try:
        response = (
            _get_supabase()
            .table("api_keys")
            .select("id, name, key_prefix, is_active, created_at, last_used_at, expires_at")
            .eq("tenant_id", tenant_id)
            .eq("is_active", True)
            .order("created_at", desc=True)
            .execute()
        )
        return {"api_keys": response.data or []}
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error listing API keys for tenant {tenant_id}: {e}")
        raise HTTPException(status_code=500, detail="Failed to list API keys")

@app.post("/api/user/api-keys", status_code=201)
async def create_api_key(payload: ApiKeyCreateRequest, tenant_id: str = Depends(get_tenant_id)):
    """Generate a new personal API key. Returns the raw key ONCE — it cannot be retrieved again."""
    raw_key, key_hash = generate_api_key()
    key_prefix = raw_key[:10]  # e.g. "vx-a1b2c3d4"

    insert_data = {
        "tenant_id": tenant_id,
        "name": payload.name,
        "key_hash": key_hash,
        "key_prefix": key_prefix,
        "expires_at": payload.expires_at,
    }

    try:
        response = _get_supabase().table("api_keys").insert(insert_data).execute()
        key_id = response.data[0]["id"]
        logger.info(f"New API key created for tenant {tenant_id}: {key_prefix}…")
        return {
            "id": key_id,
            "name": payload.name,
            "key": raw_key,      # shown once, not stored
            "key_prefix": key_prefix,
            "created_at": response.data[0]["created_at"],
        }
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error creating API key for tenant {tenant_id}: {e}")
        raise HTTPException(status_code=500, detail="Failed to create API key")

@app.delete("/api/user/api-keys/{key_id}")
async def revoke_api_key(key_id: str, tenant_id: str = Depends(get_tenant_id)):
    """Revoke (soft-delete) an API key. The key is immediately invalid."""
    try:
        # Ensure the key belongs to this tenant before revoking
        result = (
            _get_supabase()
            .table("api_keys")
            .update({"is_active": False})
            .eq("id", key_id)
            .eq("tenant_id", tenant_id)  # tenant isolation guard
            .execute()
        )
        if not result.data:
            raise HTTPException(status_code=404, detail="API key not found")
        logger.info(f"API key {key_id} revoked for tenant {tenant_id}")
        return {"status": "revoked"}
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error revoking API key {key_id}: {e}")
        raise HTTPException(status_code=500, detail="Failed to revoke API key")


# Simple cache for models
_models_cache = {}
_models_cache_time = 0

@app.get("/api/models")
async def get_models():
    """
    Returns available models, dynamically fetching from providers when possible.
    """
    global _models_cache, _models_cache_time
    import time
    
    # Cache for 5 minutes
    if time.time() - _models_cache_time < 300 and _models_cache:
        return _models_cache
        
    config = get_config()
    models_dict = dict(DEFAULT_PROVIDER_MODELS)
    
    # Dynamically fetch from OpenAI if key is present
    if config.llm_api_key and (not config.llm_base_url or "openai" in config.llm_base_url.lower()):
        try:
            async with httpx.AsyncClient() as client:
                headers = {"Authorization": f"Bearer {config.llm_api_key}"}
                # Check if there's an org set
                if os.environ.get("OPENAI_ORGANIZATION"):
                    headers["OpenAI-Organization"] = os.environ.get("OPENAI_ORGANIZATION")
                
                base_url = config.llm_base_url or "https://api.openai.com/v1"
                base_url = base_url.rstrip("/")
                
                response = await client.get(f"{base_url}/models", headers=headers, timeout=5.0)
                if response.status_code == 200:
                    data = response.json()
                    fetched_models = [m["id"] for m in data.get("data", [])]
                    
                    # Filter models exactly like LibreChat does
                    import re
                    # Keep text-davinci-003, gpt-*, o[digits], chat-latest
                    regex = re.compile(r"(text-davinci-003|gpt-|o\d+|chat-latest)")
                    exclude_regex = re.compile(r"audio|realtime")
                    
                    filtered = [m for m in fetched_models if regex.search(m) and not exclude_regex.search(m)]
                    
                    # Sort instruct models at the bottom
                    instruct_models = [m for m in filtered if "instruct" in m]
                    other_models = [m for m in filtered if "instruct" not in m]
                    
                    if other_models or instruct_models:
                        # Merge the fetched models with our default models, removing duplicates while preserving order
                        fetched_list = other_models + instruct_models
                        combined = list(dict.fromkeys(models_dict["OpenAI"] + fetched_list))
                        models_dict["OpenAI"] = combined
        except Exception as e:  # noqa: BLE001
            logging.warning(f"Failed to fetch dynamic OpenAI models: {e}")  # noqa: LOG015
            
    _models_cache = models_dict
    _models_cache_time = time.time()
    
    return models_dict


@app.get("/api/admin/stats")
def get_stats(tenant_id: str = Depends(verify_infrastructure_access)):
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
        except Exception as e:  # noqa: BLE001
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
        except Exception as e:  # noqa: BLE001
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
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error getting stats: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# check_tenant_hard_cap lives in backend.storage.quota so both api_gateway
# and mcp_server.server can import it without violating dependency direction.
from backend.storage.quota import check_tenant_hard_cap


@app.post("/api/admin/ingest")
@limiter.limit(config.rate_limit_ingest)
async def ingest_data(request: Request, ingest_request: IngestRequest, tenant_id: str = Depends(verify_infrastructure_access)):
    try:
        check_tenant_hard_cap(tenant_id, get_config())
        job = await request.app.state.redis.enqueue_job(
            "process_ingestion_task", 
            ingest_request.text, 
            tenant_id, 
            ingest_request.fast_extraction,
            ingest_request.language,
            ingest_request.custom_stop_words
        )
        return {"status": "queued", "job_id": job.job_id}
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error during ingestion: {e}")
        raise HTTPException(status_code=500, detail=str(e))


class SchemaDefinition(BaseModel):
    entities: list[str]
    relations: dict[str, dict[str, list[str]]]

@app.get("/api/admin/schema")
async def get_schema(request: Request, tenant_id: str = Depends(verify_infrastructure_access)):
    schema = await request.app.state.redis.get(f"tenant:{tenant_id}:schema")
    if schema:
        return json.loads(schema)
    raise HTTPException(status_code=404, detail="No schema defined for this tenant.")

@app.post("/api/admin/schema")
async def set_schema(request: Request, schema: SchemaDefinition, tenant_id: str = Depends(verify_infrastructure_access)):
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
    from backend.prompts import get_auto_ontology_prompt
    from openai import AsyncOpenAI
    
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
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        raise HTTPException(status_code=500, detail=f"Failed to generate valid schema: {e!s}")

class UrlIngestRequest(BaseModel):
    url: str


@app.post("/api/admin/ingest/upload")
@limiter.limit(config.rate_limit_ingest)
async def ingest_upload(
    request: Request, 
    file: UploadFile = File(...),  # noqa: B008
    fast_extraction: bool = Form(False), 
    language: str = Form("en"),
    custom_stop_words: str = Form(""),
    model: str = Form("gemini-2.5-flash-lite"),
    tenant_id: str = Depends(get_tenant_id)
):
    try:
        check_tenant_hard_cap(tenant_id, get_config())
        # Save uploaded file to temp file (with 50MB hard limit)
        MAX_FILE_SIZE = 50 * 1024 * 1024  # 50MB
        size = 0
        _, file_extension = os.path.splitext(file.filename)
        with tempfile.NamedTemporaryFile(
            delete=False, suffix=file_extension
        ) as tmp_file:
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_FILE_SIZE:
                    os.unlink(tmp_file.name)
                    raise HTTPException(
                        status_code=413,
                        detail="File exceeds the 50MB maximum upload limit. Please upload a smaller file."
                    )
                tmp_file.write(chunk)
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

        get_config()
        logger.info(f"Converting file {file.filename} with Docling...")
        converter = DocumentConverter()
        result = converter.convert(tmp_path)
        markdown_text = result.document.export_to_markdown()

        # Clean up temp file
        os.unlink(tmp_path)

        logger.info(f"Enqueueing {len(markdown_text)} bytes of markdown from {file.filename}")
        
        parsed_stop_words = [w.strip() for w in custom_stop_words.split(",")] if custom_stop_words else []
        
        job = await request.app.state.redis.enqueue_job(
            "process_ingestion_task", 
            markdown_text, 
            tenant_id, 
            fast_extraction,
            language,
            parsed_stop_words,
            model
        )
        return {"status": "queued", "job_id": job.job_id}
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error during file ingestion: {e}")
        raise HTTPException(status_code=500, detail=str(e))


class UrlIngestRequest(BaseModel):  # noqa: F811
    url: str
    fast_extraction: bool = False
    language: str = "en"
    custom_stop_words: list[str] = []
    model: str = "gemini-2.5-flash-lite"

@app.post("/api/admin/ingest/url")
@limiter.limit(config.rate_limit_ingest)
async def ingest_url(request: Request, url_request: UrlIngestRequest, tenant_id: str = Depends(verify_infrastructure_access)):
    try:
        check_tenant_hard_cap(tenant_id, get_config())
        get_config()
        logger.info(f"Converting URL {url_request.url} with Docling...")
        converter = DocumentConverter()
        result = converter.convert(url_request.url)
        markdown_text = result.document.export_to_markdown()

        logger.info(f"Enqueueing {len(markdown_text)} bytes of markdown from {url_request.url}")
        job = await request.app.state.redis.enqueue_job(
            "process_ingestion_task", 
            markdown_text, 
            tenant_id, 
            url_request.fast_extraction,
            url_request.language,
            url_request.custom_stop_words,
            url_request.model
        )
        return {"status": "queued", "job_id": job.job_id}
    except Exception as e:  # noqa: BLE001
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

def _activate_tenant_subscription(tenant_id: str | None, config, redis):
    if not tenant_id:
        return
    try:
        supabase_client: Client = create_client(config.supabase_url, config.supabase_service_key)
        supabase_client.table("users").update({"is_subscribed": True}).eq("id", tenant_id).execute()
        logger.info(f"Database updated: user {tenant_id} is now subscribed.")
        
        # Invalidate/update Redis cache so they get immediate access
        import asyncio
        async def _update_redis():
            await redis.setex(f"tenant:{tenant_id}:subscription_status", 86400, "true")
        
        asyncio.create_task(_update_redis())
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Failed to update database for tenant {tenant_id}: {e}")

@app.get("/api/test-log")
async def test_log():
    logger.warning("THIS IS A TEST LOG FROM API GATEWAY")
    return {"status": "logged"}

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
        _activate_tenant_subscription(tenant_id, config, request.app.state.redis)
    else:
        logger.info(f"Unhandled Stripe event type: {event['type']}")

    return {"status": "success"}

@app.get("/api/user/export")
async def export_user_data(request: Request, tenant_id: str = Depends(get_tenant_id)):
    """GDPR Compliance: Export all user data as JSON."""
    try:
        from langgraph.checkpoint.redis.aio import AsyncRedisSaver
        
        # Get thread list
        threads = await request.app.state.redis.smembers(f"tenant:{tenant_id}:threads")
        titles = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles")
        
        export_data = {
            "tenant_id": tenant_id,
            "export_date": __import__('datetime').datetime.now().isoformat(),
            "threads": []
        }
        
        async with AsyncRedisSaver.from_conn_string(get_config().redis_url) as memory:
            for t in threads:
                tid = t.decode("utf-8")
                title = titles.get(t, b"").decode("utf-8")
                
                config_obj = {"configurable": {"thread_id": tid}}
                state = await memory.aget_tuple(config_obj)
                
                messages = []
                if state:
                    raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
                    for m in raw_messages:
                        messages.append({
                            "type": m.__class__.__name__,
                            "content": m.content
                        })
                        
                export_data["threads"].append({
                    "thread_id": tid,
                    "title": title,
                    "messages": messages
                })
        return export_data
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        raise HTTPException(status_code=500, detail="Failed to export data")

@app.delete("/api/user/data")
async def delete_user_data(request: Request, tenant_id: str = Depends(get_tenant_id)):
    """GDPR Compliance: Delete all user data."""
    try:
        # 1. Delete from Neo4j
        neo4j_client = Neo4jStorageClient()
        try:
            # Cypher to delete all nodes belonging to tenant
            neo4j_client._driver.execute_query(
                "MATCH (n) WHERE n.tenant_id = $tenant_id DETACH DELETE n",
                {"tenant_id": tenant_id}
            )
        except Exception as e:  # noqa: BLE001
            logger.error(f"Error deleting Neo4j data: {e}")
            
        # 2. Delete from Qdrant
        qdrant_client = QdrantStorageClient()
        try:
            from qdrant_client.http import models as rest
            qdrant_client.client.delete(
                collection_name=qdrant_client.collection_name,
                points_selector=rest.FilterSelector(
                    filter=rest.Filter(
                        must=[
                            rest.FieldCondition(
                                key="tenant_id",
                                match=rest.MatchValue(value=tenant_id),
                            )
                        ]
                    )
                )
            )
        except Exception as e:  # noqa: BLE001
            logger.error(f"Error deleting Qdrant data: {e}")
            
        # 3. Delete from Redis & Postgres (Chat History)
        threads = await request.app.state.redis.smembers(f"tenant:{tenant_id}:threads")
        
        try:
            import psycopg
            async with await psycopg.AsyncConnection.connect(get_config().postgres_url) as conn:
                for thread_id in threads:
                    tid = thread_id.decode() if isinstance(thread_id, bytes) else thread_id
                    await conn.execute("DELETE FROM checkpoints WHERE thread_id = %s", (tid,))
                    await conn.execute("DELETE FROM checkpoint_writes WHERE thread_id = %s", (tid,))
                    await conn.execute("DELETE FROM checkpoint_blobs WHERE thread_id = %s", (tid,))
                await conn.commit()
        except Exception as e:  # noqa: BLE001
            logger.error(f"Error deleting Postgres chat history: {e}")

        await request.app.state.redis.delete(f"tenant:{tenant_id}:threads")
        await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_titles")
        await request.app.state.redis.delete(f"tenant:{tenant_id}:pinned_threads")
        await request.app.state.redis.delete(f"tenant:{tenant_id}:archived_threads")
        await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_projects")
        await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_timestamps")
        
        return {"status": "success", "message": "All user data deleted"}
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        raise HTTPException(status_code=500, detail="Failed to delete data")
