"""Chat endpoints — conversations, threads, messages, and feedback."""

import asyncio
import copy
import json
import logging
import time
import uuid
from typing import Any, Literal

import sentry_sdk
from backend.mcp_server.llm_loop import (
    answer_question,
    generate_chat_title,
    setup_postgres_checkpointer_once,
    stream_answer_question,
)
from backend.mcp_server.orchestrator import _get_workflow
from backend.security.moderation import moderate_text
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from langchain_core.messages import AIMessage, HumanMessage
from pydantic import BaseModel, Field

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
    custom_system_prompt: str | None = None
    mode: str = "fast"


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


class ImportedMessage(BaseModel):
    id: str
    role: Literal["user", "assistant"]
    content: str
    feedback: int = 0
    model_name: str | None = None
    metrics: dict | None = None
    activity: list[dict] = Field(default_factory=list)


class ImportedThread(BaseModel):
    thread_id: str
    title: str
    is_pinned: bool = False
    is_archived: bool = False
    project_id: str | None = None
    timestamp: float | None = None
    messages: list[ImportedMessage] = Field(default_factory=list)


class ImportThreadsRequest(BaseModel):
    threads: list[ImportedThread]


def _friendly_provider_error(error: Exception) -> str:
    """Return actionable provider errors without exposing raw SDK payloads."""
    message = str(error).lower()
    if "model_not_found" in message or "does not have access to model" in message:
        return "The selected model is unavailable. Please choose another model."
    if "ratelimit" in message or "rate limit" in message or "quota" in message:
        return (
            "This provider has reached its quota or rate limit. "
            "Please switch models or try again later."
        )
    return f"Internal server error: {type(error).__name__}: {error!s}"


async def _generate_and_save_title(
    question,
    tenant_id,
    thread_id,
    redis,
    api_key_override=None,
    base_url_override=None,
    model_override=None,
):
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
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Error generating title for thread {thread_id}: {e}")
        return None


def _process_single_message(msg, tool_results, feedback_dict):
    msg_type = msg.__class__.__name__
    if msg_type not in ["HumanMessage", "AIMessage"]:
        return None
    if msg_type == "HumanMessage" and msg.content:
        content_str = str(msg.content)
        if content_str.startswith(
            (
                "Here is the context retrieved from the database:",
                "Web Search Fallback Context:",
            )
        ):
            return None
    msg_id = getattr(msg, "id", None)
    if not msg_id:
        msg_id = getattr(msg, "additional_kwargs", {}).get("id") or str(id(msg))
    metrics = getattr(msg, "additional_kwargs", {}).get("metrics")
    tool_events = []
    if hasattr(msg, "tool_calls") and msg.tool_calls:
        for tc in msg.tool_calls:
            tool_events.append(
                {
                    "id": tc.get("id", ""),
                    "name": tc.get("name", "tool"),
                    "args": tc.get("args", {}),
                    "result": tool_results.get(tc.get("id"), ""),
                    "isComplete": True,
                }
            )
    activity = []
    saved_activity = getattr(msg, "additional_kwargs", {}).get("activity")
    if isinstance(saved_activity, list):
        activity = saved_activity
    if tool_events:
        activity = [
            {
                "number": 1,
                "name": "Tool activity",
                "description": "Tools used while preparing this answer.",
                "status": "complete",
                "toolEvents": tool_events,
            }
        ] + activity
    return {
        "id": str(msg_id),
        "role": "user" if msg_type == "HumanMessage" else "assistant",
        "content": msg.content,
        "feedback": int(feedback_dict.get(str(msg_id), 0)),
        "model_name": getattr(msg, "additional_kwargs", {}).get("model_name"),
        "metrics": metrics if isinstance(metrics, dict) else None,
        "toolEvents": tool_events,
        "activity": activity,
    }


def _extract_messages_from_state(
    raw_messages: list,
    feedback_dict: dict | None = None,
    activity_history: list[list[dict]] | None = None,
) -> list:
    if feedback_dict is None:
        feedback_dict = {}
    tool_results = {}
    for msg in raw_messages:
        if (
            getattr(msg, "type", "") == "tool"
            or msg.__class__.__name__ == "ToolMessage"
        ):
            tool_results[msg.tool_call_id] = msg.content
    messages = [
        p
        for msg in raw_messages
        if (p := _process_single_message(msg, tool_results, feedback_dict))
    ]
    if activity_history:
        assistant_messages = [
            message
            for message in messages
            if message["role"] == "assistant" and not message["toolEvents"]
        ]
        for message, activity in zip(
            assistant_messages[-len(activity_history) :], activity_history
        ):
            message["activity"] = activity
    return messages


def _record_activity_event(
    activity: list[dict], event: dict
) -> None:
    event_type = event.get("event")
    if event_type == "on_step_start":
        activity.append(
            {
                "number": int(event.get("step") or len(activity) + 1),
                "name": event.get("name") or "Activity",
                "description": event.get("description") or "",
                "status": "running",
                "toolEvents": [],
            }
        )
        return
    if not activity:
        return
    if event_type == "on_tool_start":
        activity[-1]["toolEvents"].append(
            {
                "id": event.get("run_id") or "",
                "name": event.get("name") or "tool",
                "args": (event.get("data") or {}).get("input") or {},
                "isComplete": False,
            }
        )
        return
    if event_type != "on_tool_end":
        return
    run_id = event.get("run_id")
    for step in activity:
        for tool in step["toolEvents"]:
            if tool["id"] != run_id:
                continue
            data = event.get("data") or {}
            tool.update(
                {
                    "isComplete": True,
                    "result": data.get("artifact") or data.get("output"),
                    "durationMs": event.get("duration_ms"),
                    "summary": event.get("summary"),
                }
            )
            if event.get("status") == "error":
                step["status"] = "error"


def _complete_activity(activity: list[dict]) -> None:
    for step in activity:
        if step["status"] == "running":
            step["status"] = "complete"


async def _save_activity_history(
    redis, tenant_id: str, thread_id: str, activity: list[dict]
) -> None:
    if tenant_id == "local_guest" or not activity:
        return
    key = f"tenant:{tenant_id}:thread_activities"
    existing = await redis.hget(key, thread_id)
    history = json.loads(existing.decode("utf-8")) if existing else []
    history.append(
        {
            "activity": activity,
            "response_at": time.time(),
        }
    )
    await redis.hset(key, thread_id, json.dumps(history))


def _build_thread_list(threads, titles, pinned, archived, projects, timestamps):
    thread_list = []
    for t in threads:
        tid = t.decode("utf-8")
        title = titles.get(t, b"").decode("utf-8") or "New Chat"
        try:
            ts = float(timestamps.get(t, b"0").decode("utf-8"))
        except ValueError:
            ts = 0.0
        thread_list.append(
            {
                "thread_id": tid,
                "title": title,
                "is_pinned": t in pinned,
                "is_archived": t in archived,
                "project_id": projects.get(t, b"").decode("utf-8") or None,
                "_timestamp": ts,
            }
        )
    thread_list.sort(key=lambda x: x["_timestamp"], reverse=True)
    for t in thread_list:
        del t["_timestamp"]
    return thread_list


def _to_imported_langchain_messages(messages: list[ImportedMessage]):
    imported = []
    for message in messages:
        message_kwargs: dict[str, Any] = {"id": message.id}
        if message.model_name:
            message_kwargs["model_name"] = message.model_name
        if message.metrics:
            message_kwargs["metrics"] = message.metrics
        if message.activity:
            message_kwargs["activity"] = message.activity
        message_type = HumanMessage if message.role == "user" else AIMessage
        imported.append(
            message_type(
                content=message.content,
                id=message.id,
                additional_kwargs=message_kwargs,
            )
        )
    return imported


async def _stream_events(
    chat_request, tenant_id, thread_id, api_key_override, title_task, redis
):
    activity: list[dict] = []
    try:
        yield f"data: {json.dumps({'event': 'metadata', 'data': {'thread_id': thread_id}})}\n\n"
        ts = chat_request.tool_settings or {}
        if chat_request.custom_system_prompt:
            ts["custom_system_prompt"] = chat_request.custom_system_prompt

        async for event in stream_answer_question(
            chat_request.question,
            tenant_id=tenant_id,
            thread_id=thread_id,
            is_temporary=chat_request.is_temporary,
            api_key_override=api_key_override,
            base_url_override=chat_request.base_url,
            model_override=chat_request.model,
            calculate_grounding=chat_request.calculate_grounding,
            tool_settings=ts,
        ):
            _record_activity_event(activity, event)

            def custom_encoder(obj):
                if hasattr(obj, "model_dump"):
                    return obj.model_dump()
                if hasattr(obj, "dict"):
                    return obj.dict()
                return str(obj)

            yield f"data: {json.dumps(event, default=custom_encoder)}\n\n"
        if title_task:
            try:
                title = await asyncio.wait_for(title_task, timeout=10.0)
                if title:
                    yield f"data: {json.dumps({'event': 'metadata', 'data': {'thread_title': title}})}\n\n"
            except Exception as e:
                logger.error(f"Error waiting for title task: {e}")
        _complete_activity(activity)
        await _save_activity_history(redis, tenant_id, thread_id, activity)
        yield "data: [DONE]\n\n"
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.exception("Error in streaming")
        yield f"data: {json.dumps({'error': _friendly_provider_error(e)})}\n\n"
        yield "data: [DONE]\n\n"


async def notify_sync_event(
    redis_client, tenant_id: str, event_type: str, data: dict | None = None
):
    if tenant_id == "local_guest":
        return
    payload = {"event": event_type, "data": data or {}}
    try:
        await redis_client.publish(
            f"tenant:{tenant_id}:sync_events", json.dumps(payload)
        )
    except Exception as e:
        logger.error(f"Failed to publish sync event: {e}")


async def _delete_postgres_checkpoints(thread_ids: list[str]) -> None:
    if not thread_ids:
        return
    try:
        from backend.config import get_config as _get_config

        config_obj = _get_config()
        if not config_obj.postgres_url:
            return
        import psycopg

        async with await psycopg.AsyncConnection.connect(
            config_obj.postgres_url
        ) as conn:
            await conn.execute(
                "DELETE FROM checkpoints WHERE thread_id = ANY(%s)", (thread_ids,)
            )
            await conn.execute(
                "DELETE FROM checkpoint_writes WHERE thread_id = ANY(%s)", (thread_ids,)
            )
            await conn.execute(
                "DELETE FROM checkpoint_blobs WHERE thread_id = ANY(%s)", (thread_ids,)
            )
            await conn.commit()
    except Exception as e:
        logger.debug(
            f"Failed to delete Postgres checkpoints for threads {thread_ids}: {e}"
        )


def register_chat_routes(
    app_router, get_tenant_id, verify_infrastructure_access, limiter, config
):
    """Register all chat routes with injected auth dependencies."""

    @app_router.get("/api/chat/sync")
    async def chat_sync_stream(
        request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        if tenant_id == "local_guest":
            return StreamingResponse(iter([]))

        async def event_generator():
            pubsub = request.app.state.redis.pubsub()
            await pubsub.subscribe(f"tenant:{tenant_id}:sync_events")
            try:
                async for message in pubsub.listen():
                    if message["type"] == "message":
                        data = message["data"].decode("utf-8")
                        yield f"data: {data}\n\n"
            except asyncio.CancelledError:
                pass
            except Exception as e:
                logger.error(f"SSE error: {e}")
            finally:
                await pubsub.unsubscribe()

        return StreamingResponse(event_generator(), media_type="text/event-stream")

    @app_router.post("/api/chat/threads/import")
    async def import_threads(
        payload: ImportThreadsRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Merge device-local threads into the authenticated tenant.

        Existing tenant threads are never overwritten. A checkpoint already
        present for a thread makes retries idempotent after partial failures.
        """
        if tenant_id == "local_guest":
            raise HTTPException(status_code=401, detail="Authentication required")

        from backend.config import get_config as _get_config
        from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

        config_obj = _get_config()
        if not config_obj.postgres_url:
            raise HTTPException(
                status_code=503, detail="Chat migration is temporarily unavailable"
            )

        imported_count = 0
        skipped_count = 0
        async with AsyncPostgresSaver.from_conn_string(
            config_obj.postgres_url
        ) as memory:
            await setup_postgres_checkpointer_once(memory, config_obj.postgres_url)
            workflow = _get_workflow()
            app = workflow.compile(checkpointer=memory)
            for thread in payload.threads:
                thread_key = f"tenant:{tenant_id}:threads"
                if await request.app.state.redis.sismember(
                    thread_key, thread.thread_id
                ):
                    skipped_count += 1
                    continue

                checkpoint = await memory.aget_tuple(
                    {"configurable": {"thread_id": thread.thread_id}}
                )
                if checkpoint:
                    skipped_count += 1
                    continue

                await app.aupdate_state(
                    {"configurable": {"thread_id": thread.thread_id}},
                    {"messages": _to_imported_langchain_messages(thread.messages)},
                )
                await request.app.state.redis.sadd(thread_key, thread.thread_id)
                await request.app.state.redis.hset(
                    f"tenant:{tenant_id}:thread_titles",
                    thread.thread_id,
                    thread.title[:200] or "Imported Chat",
                )
                await request.app.state.redis.hset(
                    f"tenant:{tenant_id}:thread_timestamps",
                    thread.thread_id,
                    str(thread.timestamp or time.time()),
                )
                for message in thread.messages:
                    if message.feedback:
                        await request.app.state.redis.hset(
                            f"tenant:{tenant_id}:message_feedback",
                            message.id,
                            message.feedback,
                        )
                if thread.is_pinned:
                    await request.app.state.redis.sadd(
                        f"tenant:{tenant_id}:pinned_threads", thread.thread_id
                    )
                if thread.is_archived:
                    await request.app.state.redis.sadd(
                        f"tenant:{tenant_id}:archived_threads", thread.thread_id
                    )
                project_exists = False
                if thread.project_id:
                    project_exists = (
                        await request.app.state.redis.hget(
                            f"tenant:{tenant_id}:projects", thread.project_id
                        )
                        is not None
                    )
                if project_exists:
                    await request.app.state.redis.hset(
                        f"tenant:{tenant_id}:thread_projects",
                        thread.thread_id,
                        thread.project_id,
                    )
                imported_count += 1

        return {"imported": imported_count, "skipped": skipped_count}

    @app_router.post("/api/chat", response_model=ChatResponse)
    @limiter.limit(config.rate_limit_chat)
    async def chat_endpoint(
        request: Request,
        chat_request: ChatRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        logger.warning(
            f"Received question: {chat_request.question} for tenant: {tenant_id} | tool_settings: {chat_request.tool_settings}"
        )
        if not chat_request.model:
            raise HTTPException(status_code=400, detail="No AI model selected")

        if chat_request.calculate_grounding:
            await verify_infrastructure_access(request, tenant_id)

        # Override the base_url if a local model is chosen and a local url is provided
        from backend.routes.admin import _models_cache

        local_url_header = request.headers.get("x-byod-local-url")
        if local_url_header and chat_request.model in _models_cache.get("Local", []):
            chat_request.base_url = local_url_header
            # Local endpoints don't need a real API key, but we provide a dummy one to pass checks
            chat_request.api_key = "dummy"

        # This is a pure Bring Your Own Key (BYOK) service.
        # ALL users (guest, free, and paid) MUST supply their own API key.
        # This guarantees the server never pays for inference costs.
        if not chat_request.api_key:
            raise HTTPException(
                status_code=403,
                detail="You must provide your own LLM API key. Add your key in Settings → API Keys.",
            )

        api_key_override = chat_request.api_key or None
        is_flagged = await moderate_text(
            chat_request.question, api_key=api_key_override
        )
        if is_flagged:
            raise HTTPException(
                status_code=400, detail="Message flagged by content moderation policy."
            )
        try:
            thread_id = chat_request.thread_id or str(uuid.uuid4())
            title_task = None
            if not chat_request.is_temporary:
                added = await request.app.state.redis.sadd(
                    f"tenant:{tenant_id}:threads", thread_id
                )
                await request.app.state.redis.hset(
                    f"tenant:{tenant_id}:thread_timestamps", thread_id, str(time.time())
                )
                if added == 1:
                    initial_title = (
                        chat_request.question[:40] + "..."
                        if len(chat_request.question) > 40
                        else chat_request.question
                    )
                    await request.app.state.redis.hset(
                        f"tenant:{tenant_id}:thread_titles", thread_id, initial_title
                    )
                    title_task = asyncio.create_task(
                        _generate_and_save_title(
                            chat_request.question,
                            tenant_id,
                            thread_id,
                            request.app.state.redis,
                            api_key_override=api_key_override,
                            base_url_override=chat_request.base_url,
                            model_override=chat_request.model,
                        )
                    )
            if chat_request.stream:
                return StreamingResponse(
                    _stream_events(
                        chat_request,
                        tenant_id,
                        thread_id,
                        api_key_override,
                        title_task,
                        request.app.state.redis,
                    ),
                    media_type="text/event-stream",
                )
            # Inject custom_system_prompt into tool_settings
            ts = chat_request.tool_settings or {}
            if chat_request.custom_system_prompt:
                ts["custom_system_prompt"] = chat_request.custom_system_prompt

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
                tool_settings=ts,
            )
            return ChatResponse(
                answer=answer,
                context=context,
                grounding_score=metrics.get("grounding_score") if metrics else None,
                metrics=metrics or None,
                thread_id=thread_id,
            )
        except HTTPException:
            raise  # Re-raise FastAPI errors with their original details
        except TimeoutError as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Timeout error processing question")
            raise HTTPException(status_code=504, detail=f"Request timeout: {e!s}")
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error processing question")
            raise HTTPException(
                status_code=500,
                detail=_friendly_provider_error(e),
            )

    @app_router.get("/api/chat/threads")
    async def list_threads(request: Request, tenant_id: str = Depends(get_tenant_id)):
        """Returns a list of all thread IDs belonging to the tenant."""
        logger.info(f"LIST THREADS CALLED FOR TENANT: {tenant_id}")
        # Guest users store threads locally on-device — nothing to return from the server.
        if tenant_id == "local_guest":
            return {"threads": []}
        try:
            (
                threads,
                titles,
                pinned,
                archived,
                projects,
                timestamps,
            ) = await asyncio.gather(
                request.app.state.redis.smembers(f"tenant:{tenant_id}:threads"),
                request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles"),
                request.app.state.redis.smembers(f"tenant:{tenant_id}:pinned_threads"),
                request.app.state.redis.smembers(f"tenant:{tenant_id}:archived_threads"),
                request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_projects"),
                request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_timestamps"),
            )
            return {
                "threads": _build_thread_list(
                    threads, titles, pinned, archived, projects, timestamps
                )
            }
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error listing threads")
            raise HTTPException(
                status_code=500,
                detail=f"Internal server error: {type(e).__name__}: {e!s}",
            )

    @app_router.get("/api/chat/threads/{thread_id}")
    async def get_thread_history(
        thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        """Returns the message history for a specific thread."""
        try:
            if tenant_id == "local_guest":
                return {"messages": []}

            is_owner = await request.app.state.redis.sismember(
                f"tenant:{tenant_id}:threads", thread_id
            )
            if not is_owner:
                raise HTTPException(
                    status_code=403, detail="Thread not found or access denied."
                )

            from backend.config import get_config as _get_config

            config_obj = _get_config()

            if not config_obj.postgres_url:
                return {"messages": []}

            from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

            async with AsyncPostgresSaver.from_conn_string(
                config_obj.postgres_url
            ) as memory:
                await setup_postgres_checkpointer_once(memory, config_obj.postgres_url)
                state = await memory.aget_tuple(
                    {"configurable": {"thread_id": thread_id}}
                )
            if not state:
                return {"messages": []}
            raw_messages = state.checkpoint.get("channel_values", {}).get(
                "messages", []
            )
            feedback_dict = {}
            try:
                feedbacks_raw = await request.app.state.redis.hgetall(
                    f"tenant:{tenant_id}:message_feedback"
                )
                for k, v in feedbacks_raw.items():
                    feedback_dict[k.decode("utf-8")] = int(v.decode("utf-8"))
            except Exception as e:
                sentry_sdk.capture_exception(e)
                logger.error(f"Failed to fetch feedback: {e}")
            activity_history = []
            try:
                activity_raw = await request.app.state.redis.hget(
                    f"tenant:{tenant_id}:thread_activities", thread_id
                )
                if activity_raw:
                    decoded = json.loads(activity_raw.decode("utf-8"))
                    if isinstance(decoded, list):
                        activity_history = [
                            item.get("activity", [])
                            if isinstance(item, dict)
                            else item
                            for item in decoded
                            if isinstance(item, (dict, list))
                        ]
                        response_times = [
                            item.get("response_at")
                            for item in decoded
                            if isinstance(item, dict)
                        ]
                        assistant_messages = [
                            message
                            for message in raw_messages
                            if message.__class__.__name__ == "AIMessage"
                        ]
                        for message, response_at in zip(
                            assistant_messages[-len(response_times) :],
                            response_times,
                        ):
                            if response_at is not None:
                                message.additional_kwargs.setdefault(
                                    "metrics", {}
                                )["response_at"] = response_at
            except Exception as e:
                sentry_sdk.capture_exception(e)
                logger.error(f"Failed to fetch activity history: {e}")
            return {
                "messages": _extract_messages_from_state(
                    raw_messages, feedback_dict, activity_history
                )
            }
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception(f"Error fetching thread {thread_id}")
            raise HTTPException(
                status_code=500,
                detail=f"Internal server error: {type(e).__name__}: {e!s}",
            )

    @app_router.post("/api/chat/threads/{thread_id}/share")
    async def share_thread(
        thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        if tenant_id == "local_guest":
            raise HTTPException(
                status_code=501, detail="Sharing not supported in stateless mode"
            )

        is_owner = await request.app.state.redis.sismember(
            f"tenant:{tenant_id}:threads", thread_id
        )
        if not is_owner:
            raise HTTPException(status_code=403, detail="Access denied")
        try:
            messages_out = []
            from backend.config import get_config as _get_config

            config_obj = _get_config()
            if config_obj.postgres_url:
                from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

                async with AsyncPostgresSaver.from_conn_string(
                    config_obj.postgres_url
                ) as memory:
                    await setup_postgres_checkpointer_once(memory, config_obj.postgres_url)
                    state = await memory.aget_tuple(
                        {"configurable": {"thread_id": thread_id}}
                    )
                if state:
                    raw_messages = state.checkpoint.get("channel_values", {}).get(
                        "messages", []
                    )
                    messages_out = _extract_messages_from_state(raw_messages)
            share_id = str(uuid.uuid4())
            titles = await request.app.state.redis.hgetall(
                f"tenant:{tenant_id}:thread_titles"
            )
            title = titles.get(thread_id.encode(), b"").decode("utf-8")
            share_data = {"title": title or "Shared Chat", "messages": messages_out}
            await request.app.state.redis.set(
                f"share:{share_id}", json.dumps(share_data)
            )
            await request.app.state.redis.expire(f"share:{share_id}", 30 * 24 * 60 * 60)
            return {"share_id": share_id}
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error sharing thread")
            raise HTTPException(
                status_code=500,
                detail=f"Internal server error: {type(e).__name__}: {e!s}",
            )

    @app_router.get("/share/{share_id}")
    async def get_shared_thread(share_id: str, request: Request):
        data = await request.app.state.redis.get(f"share:{share_id}")
        if not data:
            raise HTTPException(
                status_code=404, detail="Shared link not found or expired"
            )
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
                state = await memory.aget_tuple(
                    {"configurable": {"thread_id": thread_id}}
                )
            if not state:
                return {"messages": []}
            raw_messages = state.checkpoint.get("channel_values", {}).get(
                "messages", []
            )
            return {"messages": _extract_messages_from_state(raw_messages, {})}
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error")
            raise HTTPException(
                status_code=500,
                detail=f"Internal server error: {type(e).__name__}: {e!s}",
            )

    @app_router.post("/api/chat/messages/{message_id}/feedback")
    async def submit_feedback(
        message_id: str,
        payload: FeedbackRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        try:
            if payload.value == 0:
                await request.app.state.redis.hdel(
                    f"tenant:{tenant_id}:message_feedback", message_id
                )
            else:
                await request.app.state.redis.hset(
                    f"tenant:{tenant_id}:message_feedback", message_id, payload.value
                )
            return {"status": "ok"}
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error")
            raise HTTPException(
                status_code=500,
                detail=f"Internal server error: {type(e).__name__}: {e!s}",
            )

    @app_router.put("/api/chat/messages/{message_id}")
    async def edit_message(
        message_id: str,
        payload: EditRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        try:
            if tenant_id != "local_guest":
                is_owner = await request.app.state.redis.sismember(
                    f"tenant:{tenant_id}:threads", payload.thread_id
                )
                if not is_owner:
                    raise HTTPException(status_code=404, detail="Thread not found")

            from backend.config import get_config as _get_config
            from langgraph.checkpoint.redis.aio import AsyncRedisSaver

            config_obj = _get_config()
            if config_obj.postgres_url:
                from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

                saver_ctx = AsyncPostgresSaver.from_conn_string(config_obj.postgres_url)
            else:
                from langgraph.checkpoint.redis.aio import AsyncRedisSaver

                saver_ctx = AsyncRedisSaver.from_conn_string(config_obj.redis_url)

            async with saver_ctx as memory:
                if config_obj.postgres_url:
                    await setup_postgres_checkpointer_once(
                        memory, config_obj.postgres_url
                    )
                state = await memory.aget_tuple(
                    {"configurable": {"thread_id": payload.thread_id}}
                )
                if not state:
                    raise HTTPException(status_code=404, detail="Thread not found")
                raw_messages = state.checkpoint.get("channel_values", {}).get(
                    "messages", []
                )
                target_msg = None
                for msg in raw_messages:
                    msg_id = (
                        getattr(msg, "id", None)
                        or getattr(msg, "additional_kwargs", {}).get("id")
                        or str(id(msg))
                    )
                    if str(msg_id) == message_id:
                        msg.content = payload.content
                        target_msg = msg
                        break
                if target_msg:
                    from backend.mcp_server.orchestrator import _get_workflow

                    workflow = _get_workflow()
                    app = workflow.compile(checkpointer=memory)
                    await app.aupdate_state(
                        {"configurable": {"thread_id": payload.thread_id}},
                        {"messages": [target_msg]},
                    )
            return {"status": "ok"}
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error")
            raise HTTPException(
                status_code=500,
                detail=f"Internal server error: {type(e).__name__}: {e!s}",
            )

    @app_router.post("/api/chat/threads/{thread_id}/regenerate")
    async def regenerate_response(
        thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        return {"status": "ok", "message": "Regenerate triggered (mock)"}

    @app_router.put("/api/chat/threads/{thread_id}/title")
    async def rename_thread(
        thread_id: str,
        payload: TitleRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        if tenant_id != "local_guest":
            is_owner = await request.app.state.redis.sismember(
                f"tenant:{tenant_id}:threads", thread_id
            )
            if not is_owner:
                raise HTTPException(status_code=404, detail="Thread not found")
        await request.app.state.redis.hset(
            f"tenant:{tenant_id}:thread_titles", thread_id, payload.title
        )
        return {"status": "ok"}

    @app_router.post("/api/chat/threads/{thread_id}/pin")
    async def toggle_pin_thread(
        thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        if tenant_id != "local_guest":
            is_owner = await request.app.state.redis.sismember(
                f"tenant:{tenant_id}:threads", thread_id
            )
            if not is_owner:
                raise HTTPException(status_code=404, detail="Thread not found")
        is_pinned = await request.app.state.redis.sismember(
            f"tenant:{tenant_id}:pinned_threads", thread_id
        )
        if is_pinned:
            await request.app.state.redis.srem(
                f"tenant:{tenant_id}:pinned_threads", thread_id
            )
            return {"status": "unpinned"}
        await request.app.state.redis.sadd(
            f"tenant:{tenant_id}:pinned_threads", thread_id
        )
        return {"status": "pinned"}

    @app_router.post("/api/chat/threads/{thread_id}/archive")
    async def toggle_archive_thread(
        thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        if tenant_id != "local_guest":
            is_owner = await request.app.state.redis.sismember(
                f"tenant:{tenant_id}:threads", thread_id
            )
            if not is_owner:
                raise HTTPException(status_code=404, detail="Thread not found")
        is_archived = await request.app.state.redis.sismember(
            f"tenant:{tenant_id}:archived_threads", thread_id
        )
        if is_archived:
            await request.app.state.redis.srem(
                f"tenant:{tenant_id}:archived_threads", thread_id
            )
            return {"status": "unarchived"}
        await request.app.state.redis.sadd(
            f"tenant:{tenant_id}:archived_threads", thread_id
        )
        return {"status": "archived"}

    @app_router.delete("/api/chat/threads/{thread_id}")
    async def delete_thread(
        thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        await asyncio.gather(
            request.app.state.redis.srem(f"tenant:{tenant_id}:threads", thread_id),
            request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_titles", thread_id),
            request.app.state.redis.srem(f"tenant:{tenant_id}:pinned_threads", thread_id),
            request.app.state.redis.srem(f"tenant:{tenant_id}:archived_threads", thread_id),
            request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_projects", thread_id),
            request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_timestamps", thread_id),
            request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_activities", thread_id),
        )
        await _delete_postgres_checkpoints([thread_id])
        return {"status": "deleted"}

    @app_router.delete("/api/chat/threads")
    async def delete_all_threads(
        request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        threads = await request.app.state.redis.smembers(f"tenant:{tenant_id}:threads")
        tids = [
            t.decode("utf-8") if isinstance(t, bytes) else str(t)
            for t in (threads or [])
        ]
        await asyncio.gather(
            request.app.state.redis.delete(f"tenant:{tenant_id}:threads"),
            request.app.state.redis.delete(f"tenant:{tenant_id}:thread_titles"),
            request.app.state.redis.delete(f"tenant:{tenant_id}:pinned_threads"),
            request.app.state.redis.delete(f"tenant:{tenant_id}:archived_threads"),
            request.app.state.redis.delete(f"tenant:{tenant_id}:thread_projects"),
            request.app.state.redis.delete(f"tenant:{tenant_id}:thread_timestamps"),
            request.app.state.redis.delete(f"tenant:{tenant_id}:thread_activities"),
        )
        if tids:
            await _delete_postgres_checkpoints(tids)
        return {"status": "all_deleted"}

    @app_router.post("/api/chat/threads/{thread_id}/duplicate")
    async def duplicate_thread(
        thread_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        new_thread_id = str(uuid.uuid4())

        if tenant_id == "local_guest":
            return {"status": "ok", "new_thread_id": new_thread_id}

        is_owner = await request.app.state.redis.sismember(
            f"tenant:{tenant_id}:threads", thread_id
        )
        if not is_owner:
            raise HTTPException(
                status_code=403, detail="Thread not found or access denied."
            )

        titles = await request.app.state.redis.hgetall(
            f"tenant:{tenant_id}:thread_titles"
        )
        old_title = titles.get(thread_id.encode(), b"").decode("utf-8")
        new_title = f"{old_title} (Copy)" if old_title else "New Chat (Copy)"
        await request.app.state.redis.hset(
            f"tenant:{tenant_id}:thread_titles", new_thread_id, new_title
        )
        await request.app.state.redis.sadd(f"tenant:{tenant_id}:threads", new_thread_id)

        try:
            from backend.config import get_config as _get_config

            config_obj = _get_config()

            if config_obj.postgres_url:
                from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

                async with AsyncPostgresSaver.from_conn_string(
                    config_obj.postgres_url
                ) as memory:
                    await setup_postgres_checkpointer_once(memory, config_obj.postgres_url)
                    state = await memory.aget_tuple(
                        {"configurable": {"thread_id": thread_id}}
                    )
                    if state:
                        raw_messages = state.checkpoint.get("channel_values", {}).get(
                            "messages", []
                        )
                        if raw_messages:
                            copied_messages = copy.deepcopy(raw_messages)
                            for msg in copied_messages:
                                msg.id = str(uuid.uuid4())
                                if (
                                    hasattr(msg, "additional_kwargs")
                                    and "id" in msg.additional_kwargs
                                ):
                                    msg.additional_kwargs["id"] = msg.id
                            from backend.mcp_server.orchestrator import _get_workflow

                            workflow = _get_workflow()
                            app = workflow.compile(checkpointer=memory)
                            await app.aupdate_state(
                                {"configurable": {"thread_id": new_thread_id}},
                                {"messages": copied_messages},
                            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Error duplicating LangGraph state: {e}")
        return {"status": "ok", "new_thread_id": new_thread_id}
