"""Chat endpoints — conversations, threads, messages, and feedback."""

import asyncio
import copy
import json
import logging
import time
import uuid

import sentry_sdk
from backend.mcp_server.llm_loop import (
    answer_question,
    generate_chat_title,
    stream_answer_question,
)
from backend.security.moderation import moderate_text
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["chat"])


class ChatRequest(BaseModel):
    question: str
    calculate_grounding: bool = False
    thread_id: str | None = None
    stream: bool = False
    is_temporary: bool = False
    api_key: str | None = None
    base_url: str | None = None
    model: str | None = None
    tool_settings: dict | None = None


class ChatResponse(BaseModel):
    answer: str
    context: str | None = None
    grounding_score: float | None = None
    metrics: dict[str, float | str | None] | None = None
    thread_id: str | None = None


class FeedbackRequest(BaseModel):
    value: int


class EditRequest(BaseModel):
    content: str
    thread_id: str


class TitleRequest(BaseModel):
    title: str


async def _generate_and_save_title(question, tenant_id, thread_id, redis, api_key_override=None, base_url_override=None, model_override=None):
    try:
        title = await generate_chat_title(question, api_key_override=api_key_override, base_url_override=base_url_override, model_override=model_override)
        if not title:
            return None
        await redis.hset(f"tenant:{tenant_id}:thread_titles", thread_id, title)
        return title
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error generating title for thread {thread_id}: {e}")
        return None


def _process_single_message(msg, tool_results, feedback_dict):
    msg_type = msg.__class__.__name__
    if msg_type not in ["HumanMessage", "AIMessage"]:
        return None
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
            tool_events.append({"id": tc.get("id", ""), "name": tc.get("name", "tool"), "args": tc.get("args", {}), "result": tool_results.get(tc.get("id"), ""), "isComplete": True})
    return {"id": str(msg_id), "role": "user" if msg_type == "HumanMessage" else "assistant", "content": msg.content, "feedback": int(feedback_dict.get(str(msg_id), 0)), "model_name": getattr(msg, "additional_kwargs", {}).get("model_name"), "metrics": metrics if isinstance(metrics, dict) else None, "toolEvents": tool_events}


def _extract_messages_from_state(raw_messages: list, feedback_dict: dict | None = None) -> list:
    if feedback_dict is None:
        feedback_dict = {}
    tool_results = {}
    for msg in raw_messages:
        if getattr(msg, "type", "") == "tool" or msg.__class__.__name__ == "ToolMessage":
            tool_results[msg.tool_call_id] = msg.content
    return [p for msg in raw_messages if (p := _process_single_message(msg, tool_results, feedback_dict))]


def _build_thread_list(threads, titles, pinned, archived, projects, timestamps):
    thread_list = []
    for t in threads:
        tid = t.decode("utf-8")
        title = titles.get(t, b"").decode("utf-8") or "New Chat"
        try:
            ts = float(timestamps.get(t, b"0").decode("utf-8"))
        except ValueError:
            ts = 0.0
        thread_list.append({"thread_id": tid, "title": title, "is_pinned": t in pinned, "is_archived": t in archived, "project_id": projects.get(t, b"").decode("utf-8") or None, "_timestamp": ts})
    thread_list.sort(key=lambda x: x["_timestamp"], reverse=True)
    for t in thread_list:
        del t["_timestamp"]
    return thread_list


async def _stream_events(chat_request, tenant_id, thread_id, api_key_override, title_task):
    try:
        yield f"data: {json.dumps({'event': 'metadata', 'data': {'thread_id': thread_id}})}\n\n"
        async for event in stream_answer_question(chat_request.question, tenant_id=tenant_id, thread_id=thread_id, is_temporary=chat_request.is_temporary, api_key_override=api_key_override, base_url_override=chat_request.base_url, model_override=chat_request.model, calculate_grounding=chat_request.calculate_grounding, tool_settings=chat_request.tool_settings):
            def custom_encoder(obj):
                if hasattr(obj, 'model_dump'):
                    return obj.model_dump()
                if hasattr(obj, 'dict'):
                    return obj.dict()
                return str(obj)
            yield f"data: {json.dumps(event, default=custom_encoder)}\n\n"
        if title_task:
            try:
                title = await asyncio.wait_for(title_task, timeout=10.0)
                if title:
                    yield f"data: {json.dumps({'event': 'metadata', 'data': {'thread_title': title}})}\n\n"
            except Exception as e:  # noqa: BLE001
                logger.error(f"Error waiting for title task: {e}")
        yield "data: [DONE]\n\n"
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Error in streaming: {e}")
        yield f"data: {json.dumps({'error': str(e)})}\n\n"
        yield "data: [DONE]\n\n"


def register_chat_routes(app_router, get_tenant_id, verify_infrastructure_access, limiter, config):
    """Register all chat routes with injected auth dependencies."""

    @app_router.post("/api/chat", response_model=ChatResponse)
    @limiter.limit(config.rate_limit_chat)
    async def chat_endpoint(request: Request, chat_request: ChatRequest, tenant_id: str = Depends(verify_infrastructure_access)):
        logger.warning(f"Received question: {chat_request.question} for tenant: {tenant_id} | tool_settings: {chat_request.tool_settings}")
        if not chat_request.model:
            raise HTTPException(status_code=400, detail="No AI model selected")
        api_key_override = chat_request.api_key or None
        is_flagged = await moderate_text(chat_request.question, api_key=api_key_override)
        if is_flagged:
            raise HTTPException(status_code=400, detail="Message flagged by content moderation policy.")
        try:
            thread_id = chat_request.thread_id or str(uuid.uuid4())
            title_task = None
            if not chat_request.is_temporary:
                added = await request.app.state.redis.sadd(f"tenant:{tenant_id}:threads", thread_id)
                await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_timestamps", thread_id, str(time.time()))
                if added == 1:
                    initial_title = chat_request.question[:40] + "..." if len(chat_request.question) > 40 else chat_request.question
                    await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_titles", thread_id, initial_title)
                    title_task = asyncio.create_task(_generate_and_save_title(chat_request.question, tenant_id, thread_id, request.app.state.redis, api_key_override=api_key_override, base_url_override=chat_request.base_url, model_override=chat_request.model))
            if chat_request.stream:
                return StreamingResponse(_stream_events(chat_request, tenant_id, thread_id, api_key_override, title_task), media_type="text/event-stream")
            answer, context, metrics = await answer_question(chat_request.question, tenant_id=tenant_id, thread_id=thread_id, return_context=True, return_metrics=True, is_temporary=chat_request.is_temporary, api_key_override=api_key_override, base_url_override=chat_request.base_url, model_override=chat_request.model, calculate_grounding=chat_request.calculate_grounding, tool_settings=chat_request.tool_settings)
            return ChatResponse(answer=answer, context=context, grounding_score=metrics.get("grounding_score") if metrics else None, metrics=metrics or None, thread_id=thread_id)
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error processing question: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.get("/api/chat/threads")
    async def list_threads(request: Request, tenant_id: str = Depends(get_tenant_id)):
        """Returns a list of all thread IDs belonging to the tenant."""
        logger.info(f"LIST THREADS CALLED FOR TENANT: {tenant_id}")
        try:
            threads = await request.app.state.redis.smembers(f"tenant:{tenant_id}:threads")
            titles = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles")
            pinned = await request.app.state.redis.smembers(f"tenant:{tenant_id}:pinned_threads")
            archived = await request.app.state.redis.smembers(f"tenant:{tenant_id}:archived_threads")
            projects = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_projects")
            timestamps = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_timestamps")
            return {"threads": _build_thread_list(threads, titles, pinned, archived, projects, timestamps)}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error listing threads: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.get("/api/chat/threads/{thread_id}")
    async def get_thread_history(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
        """Returns the message history for a specific thread."""
        try:
            is_owner = await request.app.state.redis.sismember(f"tenant:{tenant_id}:threads", thread_id)
            if not is_owner:
                raise HTTPException(status_code=403, detail="Thread not found or access denied.")
            from backend.config import get_config as _get_config
            from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
            config_obj = _get_config()
            async with AsyncPostgresSaver.from_conn_string(config_obj.postgres_url) as memory:
                await memory.setup()
                state = await memory.aget_tuple({"configurable": {"thread_id": thread_id}})
            if not state:
                return {"messages": []}
            raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
            feedback_dict = {}
            try:
                feedbacks_raw = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:message_feedback")
                for k, v in feedbacks_raw.items():
                    feedback_dict[k.decode("utf-8")] = int(v.decode("utf-8"))
            except Exception as e:  # noqa: BLE001
                sentry_sdk.capture_exception(e)
                logger.error(f"Failed to fetch feedback: {e}")
            return {"messages": _extract_messages_from_state(raw_messages, feedback_dict)}
        except HTTPException:
            raise
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error fetching thread {thread_id}: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.post("/api/chat/threads/{thread_id}/share")
    async def share_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
        is_owner = await request.app.state.redis.sismember(f"tenant:{tenant_id}:threads", thread_id)
        if not is_owner:
            raise HTTPException(status_code=403, detail="Access denied")
        try:
            from backend.config import get_config as _get_config
            from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
            config_obj = _get_config()
            async with AsyncPostgresSaver.from_conn_string(config_obj.postgres_url) as memory:
                await memory.setup()
                state = await memory.aget_tuple({"configurable": {"thread_id": thread_id}})
            messages_out = []
            if state:
                raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
                messages_out = _extract_messages_from_state(raw_messages)
            share_id = str(uuid.uuid4())
            titles = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles")
            title = titles.get(thread_id.encode(), b"").decode("utf-8")
            share_data = {"title": title or "Shared Chat", "messages": messages_out}
            await request.app.state.redis.set(f"share:{share_id}", json.dumps(share_data))
            await request.app.state.redis.expire(f"share:{share_id}", 30 * 24 * 60 * 60)
            return {"share_id": share_id}
        except HTTPException:
            raise
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.get("/share/{share_id}")
    async def get_shared_thread(share_id: str, request: Request):
        data = await request.app.state.redis.get(f"share:{share_id}")
        if not data:
            raise HTTPException(status_code=404, detail="Shared link not found or expired")
        return json.loads(data)

    @app_router.get("/shared/threads/{thread_id}")
    async def get_shared_thread_history(thread_id: str, request: Request):
        try:
            is_shared = await request.app.state.redis.get(f"shared_thread:{thread_id}")
            if not is_shared:
                raise HTTPException(status_code=404, detail="Shared thread not found.")
            from backend.config import get_config as _get_config
            from langgraph.checkpoint.redis.aio import AsyncRedisSaver
            config_obj = _get_config()
            async with AsyncRedisSaver.from_conn_string(config_obj.redis_url) as memory:
                state = await memory.aget_tuple({"configurable": {"thread_id": thread_id}})
            if not state:
                return {"messages": []}
            raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
            return {"messages": _extract_messages_from_state(raw_messages, {})}
        except HTTPException:
            raise
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.post("/api/chat/messages/{message_id}/feedback")
    async def submit_feedback(message_id: str, payload: FeedbackRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
        try:
            if payload.value == 0:
                await request.app.state.redis.hdel(f"tenant:{tenant_id}:message_feedback", message_id)
            else:
                await request.app.state.redis.hset(f"tenant:{tenant_id}:message_feedback", message_id, payload.value)
            return {"status": "ok"}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.put("/api/chat/messages/{message_id}")
    async def edit_message(message_id: str, payload: EditRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
        try:
            from backend.config import get_config as _get_config
            from langgraph.checkpoint.redis.aio import AsyncRedisSaver
            config_obj = _get_config()
            async with AsyncRedisSaver.from_conn_string(config_obj.redis_url) as memory:
                state = await memory.aget_tuple({"configurable": {"thread_id": payload.thread_id}})
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
                    await memory.aupdate_state({"configurable": {"thread_id": payload.thread_id}}, {"messages": [target_msg]})
            return {"status": "ok"}
        except HTTPException:
            raise
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.post("/api/chat/threads/{thread_id}/regenerate")
    async def regenerate_response(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
        return {"status": "ok", "message": "Regenerate triggered (mock)"}

    @app_router.put("/api/chat/threads/{thread_id}/title")
    async def rename_thread(thread_id: str, payload: TitleRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
        await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_titles", thread_id, payload.title)
        return {"status": "ok"}

    @app_router.post("/api/chat/threads/{thread_id}/pin")
    async def toggle_pin_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
        is_pinned = await request.app.state.redis.sismember(f"tenant:{tenant_id}:pinned_threads", thread_id)
        if is_pinned:
            await request.app.state.redis.srem(f"tenant:{tenant_id}:pinned_threads", thread_id)
            return {"status": "unpinned"}
        await request.app.state.redis.sadd(f"tenant:{tenant_id}:pinned_threads", thread_id)
        return {"status": "pinned"}

    @app_router.post("/api/chat/threads/{thread_id}/archive")
    async def toggle_archive_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
        is_archived = await request.app.state.redis.sismember(f"tenant:{tenant_id}:archived_threads", thread_id)
        if is_archived:
            await request.app.state.redis.srem(f"tenant:{tenant_id}:archived_threads", thread_id)
            return {"status": "unarchived"}
        await request.app.state.redis.sadd(f"tenant:{tenant_id}:archived_threads", thread_id)
        return {"status": "archived"}

    @app_router.delete("/api/chat/threads/{thread_id}")
    async def delete_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
        await request.app.state.redis.srem(f"tenant:{tenant_id}:threads", thread_id)
        await request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_titles", thread_id)
        await request.app.state.redis.srem(f"tenant:{tenant_id}:pinned_threads", thread_id)
        await request.app.state.redis.srem(f"tenant:{tenant_id}:archived_threads", thread_id)
        await request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_projects", thread_id)
        return {"status": "deleted"}

    @app_router.delete("/api/chat/threads")
    async def delete_all_threads(request: Request, tenant_id: str = Depends(get_tenant_id)):
        await request.app.state.redis.delete(f"tenant:{tenant_id}:threads")
        await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_titles")
        await request.app.state.redis.delete(f"tenant:{tenant_id}:pinned_threads")
        await request.app.state.redis.delete(f"tenant:{tenant_id}:archived_threads")
        await request.app.state.redis.delete(f"tenant:{tenant_id}:thread_projects")
        return {"status": "all_deleted"}

    @app_router.post("/api/chat/threads/{thread_id}/duplicate")
    async def duplicate_thread(thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
        new_thread_id = str(uuid.uuid4())
        titles = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles")
        old_title = titles.get(thread_id.encode(), b"").decode("utf-8")
        new_title = f"{old_title} (Copy)" if old_title else "New Chat (Copy)"
        await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_titles", new_thread_id, new_title)
        await request.app.state.redis.sadd(f"tenant:{tenant_id}:threads", new_thread_id)
        try:
            from backend.config import get_config as _get_config
            from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
            config_obj = _get_config()
            async with AsyncPostgresSaver.from_conn_string(config_obj.postgres_url) as memory:
                await memory.setup()
                state = await memory.aget_tuple({"configurable": {"thread_id": thread_id}})
                if state:
                    raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
                    if raw_messages:
                        copied_messages = copy.deepcopy(raw_messages)
                        for msg in copied_messages:
                            msg.id = str(uuid.uuid4())
                            if hasattr(msg, "additional_kwargs") and "id" in msg.additional_kwargs:
                                msg.additional_kwargs["id"] = msg.id
                        await memory.aupdate_state({"configurable": {"thread_id": new_thread_id}}, {"messages": copied_messages})
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error duplicating LangGraph state: {e}")
        return {"status": "ok", "new_thread_id": new_thread_id}
