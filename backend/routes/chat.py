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

_active_thread_generations: set[str] = set()
_thread_mutation_locks: dict[str, asyncio.Lock] = {}


def _get_thread_mutation_lock(thread_id: str) -> asyncio.Lock:
    lock = _thread_mutation_locks.get(thread_id)
    if lock is None:
        lock = asyncio.Lock()
        _thread_mutation_locks[thread_id] = lock
    return lock


def _ensure_thread_not_generating(thread_id: str) -> None:
    if thread_id in _active_thread_generations:
        raise HTTPException(
            status_code=409,
            detail="Cannot modify conversation history while a response is generating.",
        )


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
    # Code Mode (Phase 1) — all optional / defaulted so existing chat
    # clients keep working unchanged.
    workspace_mode: Literal["chat", "code"] = "chat"
    repo_key: str | None = None
    branch: str | None = None
    thinking_level: Literal["low", "medium", "high"] | None = None
    execution_mode: Literal["plan", "act"] = "act"
    autonomy_mode: (
        Literal[
            "ask_all",
            "auto_read_test",
            "auto_workspace_writes",
            "autonomous",
        ]
        | None
    ) = None
    source_scope: dict | None = None


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


class CompactPreviewRequest(BaseModel):
    model: str | None = None
    api_key: str | None = None
    base_url: str | None = None
    keep_recent_turns: int = 4
    focus: str | None = None


class CompactApplyRequest(BaseModel):
    summary: str
    keep_recent_turns: int = 4


class ClearToolResultsRequest(BaseModel):
    keep_recent_turns: int = 4


class ImportedMessage(BaseModel):
    id: str
    role: Literal["user", "assistant"]
    content: str
    feedback: int = 0
    model_name: str | None = None
    metrics: dict | None = None
    activity: list[dict] = Field(default_factory=list)
    reasoning: str | None = None
    reasoning_duration_seconds: float | None = None


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


class ConfirmToolRequest(BaseModel):
    tool_name: str
    args: dict = {}
    approve: bool = False


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
    if (
        "authentication" in message
        or "401" in message
        or "invalid_api_key" in message
        or "invalid api key" in message
    ):
        return (
            "Authentication failed for the selected provider. "
            "Please check your API key or choose another model."
        )
    if "timeout" in message or "timed out" in message:
        return "The provider took too long to respond. Please try again later."
    if (
        "tool_use_failed" in message
        or "failed_generation" in message
        or "tool choice is none" in message
        or "model called a tool" in message
    ):
        return (
            "The selected model encountered a tool-calling error. "
            "Please try again or switch models."
        )
    # Raw exception details are captured server-side via Sentry/logging;
    # clients only ever receive this generic message.
    return "Internal server error. Please try again later."


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


def _reasoning_from_kwargs(msg) -> tuple[str | None, float | None]:
    """Read the persisted reasoning trace off a message, if it carries one."""
    kwargs = getattr(msg, "additional_kwargs", {}) or {}
    reasoning = kwargs.get("reasoning_content")
    if not isinstance(reasoning, str) or not reasoning:
        reasoning = None
    duration = kwargs.get("reasoning_duration_seconds")
    if isinstance(duration, bool) or not isinstance(duration, (int, float)):
        duration = None
    return reasoning, float(duration) if duration is not None else None


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
    reasoning, reasoning_duration_seconds = _reasoning_from_kwargs(msg)
    processed = {
        "id": str(msg_id),
        "role": "user" if msg_type == "HumanMessage" else "assistant",
        "content": msg.content,
        "feedback": int(feedback_dict.get(str(msg_id), 0)),
        "model_name": getattr(msg, "additional_kwargs", {}).get("model_name"),
        "metrics": metrics if isinstance(metrics, dict) else None,
        "toolEvents": tool_events,
        "activity": activity,
        "reasoning": reasoning,
        "reasoning_duration_seconds": reasoning_duration_seconds,
    }
    files_changed = getattr(msg, "additional_kwargs", {}).get("files_changed")
    if isinstance(files_changed, dict):
        processed["files_changed"] = files_changed
    return processed


def _apply_saved_reasoning(message: dict, saved: dict | None) -> None:
    """Fill reasoning from the saved per-turn record when the message
    itself does not carry a (non-empty) trace."""
    if not isinstance(saved, dict):
        return
    saved_reasoning = saved.get("reasoning")
    if (
        not message.get("reasoning")
        and isinstance(saved_reasoning, str)
        and saved_reasoning
    ):
        message["reasoning"] = saved_reasoning
    if message.get("reasoning_duration_seconds") is None:
        saved_duration = saved.get("reasoning_duration_seconds")
        if isinstance(saved_duration, (int, float)) and not isinstance(
            saved_duration, bool
        ):
            message["reasoning_duration_seconds"] = float(saved_duration)


def _sync_tool_results_from_activity(message: dict) -> None:
    """Backfill structured tool results from persisted activity when missing or raw."""
    activity = message.get("activity")
    tool_events = message.get("toolEvents")
    if not isinstance(activity, list) or not isinstance(tool_events, list):
        return

    by_id: dict[str, Any] = {}
    for step in activity:
        if not isinstance(step, dict):
            continue
        for ev in step.get("toolEvents") or []:
            if not isinstance(ev, dict):
                continue
            ev_id = ev.get("id")
            ev_result = ev.get("result")
            if ev_id and ev_result:
                by_id[ev_id] = ev_result

    if not by_id:
        return

    for te in tool_events:
        if not isinstance(te, dict):
            continue
        cur = te.get("result")
        is_raw_db_text = isinstance(cur, str) and cur.startswith(
            "Here is the context retrieved from the database:"
        )
        if (not cur or is_raw_db_text) and te.get("id") in by_id:
            te["result"] = by_id[te["id"]]


def _extract_messages_from_state(
    raw_messages: list,
    feedback_dict: dict | None = None,
    activity_history: list[list[dict]] | None = None,
    reasoning_history: list[dict | None] | None = None,
    files_changed_history: list[dict | None] | None = None,
) -> list:
    if feedback_dict is None:
        feedback_dict = {}
    tool_results = {}
    for msg in raw_messages:
        if (
            getattr(msg, "type", "") == "tool"
            or msg.__class__.__name__ == "ToolMessage"
        ):
            artifact = getattr(msg, "artifact", None)
            tool_results[msg.tool_call_id] = artifact if artifact else msg.content
    messages = [
        p
        for msg in raw_messages
        if (p := _process_single_message(msg, tool_results, feedback_dict))
    ]
    if activity_history:
        assistant_messages = _final_assistant_messages(messages)
        if assistant_messages:
            for message, activity in zip(
                assistant_messages[-len(activity_history) :],
                activity_history[-len(assistant_messages) :],
            ):
                message["activity"] = activity
    if reasoning_history:
        assistant_messages = _final_assistant_messages(messages)
        if assistant_messages:
            for message, saved_reasoning in zip(
                assistant_messages[-len(reasoning_history) :],
                reasoning_history[-len(assistant_messages) :],
            ):
                _apply_saved_reasoning(message, saved_reasoning)
    if files_changed_history:
        assistant_messages = _final_assistant_messages(messages)
        if assistant_messages:
            for message, saved_files_changed in zip(
                assistant_messages[-len(files_changed_history) :],
                files_changed_history[-len(assistant_messages) :],
            ):
                if (
                    "files_changed" not in message
                    and isinstance(saved_files_changed, dict)
                    and saved_files_changed
                ):
                    message["files_changed"] = saved_files_changed
    merged = _merge_intermediate_tool_messages(messages)
    for message in merged:
        if message.get("role") != "assistant":
            continue
        if not message.get("toolEvents") and isinstance(message.get("activity"), list):
            message["toolEvents"] = [
                event
                for step in message["activity"]
                if isinstance(step, dict)
                for event in (step.get("toolEvents") or [])
            ]
        _sync_tool_results_from_activity(message)
    return merged


def _is_intermediate_tool_message(message: dict) -> bool:
    return (
        message.get("role") == "assistant"
        and not str(message.get("content") or "").strip()
        and bool(message.get("toolEvents"))
    )


def _merge_intermediate_tool_messages(messages: list[dict]) -> list[dict]:
    """Fold tool-only assistant messages into the turn's final assistant reply."""
    merged: list[dict] = []
    pending_tool_msgs: list[dict] = []

    for message in messages:
        if _is_intermediate_tool_message(message):
            pending_tool_msgs.append(message)
            continue

        if message.get("role") != "assistant":
            if pending_tool_msgs:
                merged.extend(pending_tool_msgs)
                pending_tool_msgs.clear()
            merged.append(message)
            continue

        if pending_tool_msgs:
            inherited_events = [
                event
                for pending in pending_tool_msgs
                for event in (pending.get("toolEvents") or [])
            ]
            message["toolEvents"] = inherited_events + (
                message.get("toolEvents") or []
            )
            if not message.get("activity") and inherited_events:
                message["activity"] = [
                    {
                        "number": 1,
                        "name": "Tool activity",
                        "description": "Tools used while preparing this answer.",
                        "status": "complete",
                        "toolEvents": message["toolEvents"],
                    }
                ]
            pending_tool_msgs.clear()

        merged.append(message)

    if pending_tool_msgs:
        merged.extend(pending_tool_msgs)
    return merged


def _final_assistant_messages(messages: list[dict]) -> list[dict]:
    return [
        message
        for message in messages
        if message["role"] == "assistant" and not message["toolEvents"]
    ]


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


def _fail_activity(activity: list[dict]) -> None:
    for step in activity:
        if step["status"] == "running":
            step["status"] = "error"


async def _save_activity_history(
    redis,
    tenant_id: str,
    thread_id: str,
    activity: list[dict],
    reasoning: str | None = None,
    reasoning_duration_seconds: float | None = None,
    files_changed: dict | None = None,
) -> None:
    if tenant_id == "local_guest":
        return
    key = f"tenant:{tenant_id}:thread_activities"
    existing = await redis.hget(key, thread_id)
    history = json.loads(existing.decode("utf-8")) if existing else []
    entry: dict[str, Any] = {
        "activity": activity,
        "response_at": time.time(),
    }
    if reasoning:
        entry["reasoning"] = reasoning
    if reasoning_duration_seconds is not None:
        entry["reasoning_duration_seconds"] = float(reasoning_duration_seconds)
    if files_changed:
        # Code Mode Phase 2: the per-turn files_changed summary lives
        # in the same per-turn record as activity/reasoning, so the
        # thread-history reload path can re-attach it to the turn's
        # assistant message (see _extract_messages_from_state).
        entry["files_changed"] = files_changed
    history.append(entry)
    await redis.hset(key, thread_id, json.dumps(history))


async def _collect_turn_files_changed(
    tenant_id: str, thread_id: str, tool_settings: dict, turn_id: str
) -> dict | None:
    """Diff summary for a finished Code Mode turn, or None.

    Returns None — emitting nothing — when the turn is not Code Mode,
    when no sandbox session is bound to this thread, or when the
    session has no file edits. Never fabricates a summary: any
    failure resolves to None (and is reported to Sentry).
    """
    if (tool_settings or {}).get("workspace_mode") != "code":
        return None
    try:
        from backend.mcp_server.tool_dispatch import _resolve_sandbox_manager
        from backend.sandbox.git_diff import collect_session_diff

        manager = _resolve_sandbox_manager(tool_settings or {})
        if manager is None:
            return None
        session_id = None
        session_for_chat = getattr(manager, "session_id_for_chat", None)
        if callable(session_for_chat):
            session_id = session_for_chat(tenant_id, thread_id)
        if not session_id:
            for info in manager.list_session_infos(tenant_id):
                if getattr(info, "chat_id", None) == thread_id:
                    session_id = info.session_id
                    break
        if not session_id:
            return None
        provider = manager.provider_for(session_id)
        if provider is None:
            return None
        summary = await collect_session_diff(provider, session_id, turn_id=turn_id)
        if not summary.get("files"):
            return None
        return summary
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.warning(f"Failed to collect files_changed for thread {thread_id}: {e}")
        return None


def _count_final_ai_messages(raw_messages: list[Any]) -> int:
    return sum(
        1
        for m in raw_messages
        if (getattr(m, "type", "") == "ai" or m.__class__.__name__ == "AIMessage")
        and not getattr(m, "tool_calls", None)
    )


async def _load_thread_activity_entries(
    redis_client: Any, tenant_id: str, thread_id: str
) -> list[Any]:
    if not redis_client:
        return []
    raw = await redis_client.hget(f"tenant:{tenant_id}:thread_activities", thread_id)
    if not raw:
        return []
    decoded = raw.decode("utf-8") if isinstance(raw, bytes) else raw
    loaded = json.loads(decoded)
    return loaded if isinstance(loaded, list) else []


async def _store_thread_activity_entries(
    redis_client: Any, tenant_id: str, thread_id: str, entries: list[Any]
) -> None:
    if not redis_client:
        return
    if hasattr(redis_client, "sismember") and not await redis_client.sismember(
        f"tenant:{tenant_id}:threads", thread_id
    ):
        return
    await redis_client.hset(
        f"tenant:{tenant_id}:thread_activities",
        thread_id,
        json.dumps(entries),
    )


def _attach_activity_backup(
    new_messages: list[Any], activity_entries: list[Any]
) -> None:
    from backend.mcp_server.compaction import find_latest_compaction

    found = find_latest_compaction(new_messages)
    if found is None:
        return
    index, _ = found
    kwargs = dict(getattr(new_messages[index], "additional_kwargs", None) or {})
    kwargs["activity_backup"] = activity_entries
    new_messages[index].additional_kwargs = kwargs


async def _trim_activities_after_compact(
    redis_client: Any,
    tenant_id: str,
    thread_id: str,
    entries: list[Any],
    new_messages: list[Any],
) -> None:
    try:
        kept_ai = _count_final_ai_messages(new_messages)
        trimmed = entries[-kept_ai:] if kept_ai > 0 else []
        await _store_thread_activity_entries(
            redis_client, tenant_id, thread_id, trimmed
        )
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.warning(f"Failed to reconcile thread_activities on compact: {e}")


async def _reconcile_activities_on_restore(
    redis_client: Any,
    tenant_id: str,
    thread_id: str,
    summary_message: Any,
    record: dict[str, Any],
    restored_messages: list[Any],
) -> None:
    try:
        kwargs = getattr(summary_message, "additional_kwargs", None) or {}
        backup = kwargs.get("activity_backup")
        if not isinstance(backup, list):
            backup = record.get("activity_backup")
        if isinstance(backup, list):
            await _store_thread_activity_entries(
                redis_client, tenant_id, thread_id, backup
            )
            return
        entries = await _load_thread_activity_entries(
            redis_client, tenant_id, thread_id
        )
        restored_ai = _count_final_ai_messages(restored_messages)
        trimmed = entries[:restored_ai] if restored_ai > 0 else []
        await _store_thread_activity_entries(
            redis_client, tenant_id, thread_id, trimmed
        )
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.warning(f"Failed to reconcile thread_activities on restore: {e}")


async def _apply_compaction_tx(
    memory: Any,
    replace_messages: Any,
    redis_client: Any,
    tenant_id: str,
    thread_id: str,
    payload: CompactApplyRequest,
) -> dict[str, Any]:
    from backend.mcp_server.compaction import (
        CompactionError,
        apply_compaction,
        check_minimum_progress,
        count_messages_tokens,
        split_for_compaction,
    )

    state = await memory.aget_tuple({"configurable": {"thread_id": thread_id}})
    if not state:
        raise HTTPException(status_code=404, detail="Thread not found")
    raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
    tokens_before = count_messages_tokens(raw_messages, None)
    _, prefix, _ = split_for_compaction(raw_messages, payload.keep_recent_turns)
    try:
        new_messages = apply_compaction(
            raw_messages,
            payload.summary,
            payload.keep_recent_turns,
            tokens_before,
        )
        tokens_after = count_messages_tokens(new_messages, None)
        check_minimum_progress(tokens_before, tokens_after)
    except CompactionError as e:
        raise HTTPException(status_code=400, detail=str(e))
    activity_entries = await _load_thread_activity_entries(
        redis_client, tenant_id, thread_id
    )
    _attach_activity_backup(new_messages, activity_entries)
    await replace_messages(memory, thread_id, new_messages)
    await _trim_activities_after_compact(
        redis_client, tenant_id, thread_id, activity_entries, new_messages
    )
    return {
        "status": "ok",
        "messages_compacted": len(prefix),
        "tokens_after_estimate": tokens_after,
    }


async def _restore_compaction_tx(
    memory: Any,
    replace_messages: Any,
    redis_client: Any,
    tenant_id: str,
    thread_id: str,
) -> dict[str, Any]:
    from backend.mcp_server.compaction import (
        find_latest_compaction,
        pick_pre_compaction_messages,
    )

    config = {"configurable": {"thread_id": thread_id}}
    state = await memory.aget_tuple(config)
    if not state:
        raise HTTPException(status_code=404, detail="Thread not found")
    raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
    found = find_latest_compaction(raw_messages)
    if found is None:
        raise HTTPException(
            status_code=409,
            detail="This conversation has not been compacted.",
        )
    index, record = found
    summary_message = raw_messages[index]
    history_lists: list[Any] = []
    async for tuple_ in memory.alist(config):
        history_lists.append(
            tuple_.checkpoint.get("channel_values", {}).get("messages", [])
        )
    restored = pick_pre_compaction_messages(history_lists, record.get("compacted_at"))
    if restored is None:
        raise HTTPException(
            status_code=409,
            detail="The pre-compaction checkpoint is no longer available.",
        )
    await replace_messages(memory, thread_id, restored)
    await _reconcile_activities_on_restore(
        redis_client, tenant_id, thread_id, summary_message, record, restored
    )
    return {
        "status": "ok",
        "messages_restored": len(restored),
    }


async def _clear_tool_results_tx(
    memory: Any,
    replace_messages: Any,
    thread_id: str,
    payload: ClearToolResultsRequest,
) -> dict[str, Any]:
    from backend.mcp_server.compaction import (
        clear_old_tool_results,
        count_messages_tokens,
    )

    state = await memory.aget_tuple({"configurable": {"thread_id": thread_id}})
    if not state:
        raise HTTPException(status_code=404, detail="Thread not found")
    raw_messages = state.checkpoint.get("channel_values", {}).get("messages", [])
    new_messages, cleared = clear_old_tool_results(
        raw_messages, payload.keep_recent_turns
    )
    if cleared == 0:
        raise HTTPException(
            status_code=400,
            detail="No old tool results to clear.",
        )
    await replace_messages(memory, thread_id, new_messages)
    return {
        "status": "ok",
        "tool_results_cleared": cleared,
        "tokens_after_estimate": count_messages_tokens(new_messages, None),
    }


def _prepare_duplicated_messages(raw_messages: list[Any]) -> list[Any]:
    copied_messages = copy.deepcopy(raw_messages)
    for msg in copied_messages:
        msg.id = str(uuid.uuid4())
        kwargs = getattr(msg, "additional_kwargs", None)
        if not isinstance(kwargs, dict):
            continue
        if "id" in kwargs:
            kwargs["id"] = msg.id
        kwargs.pop("activity_backup", None)
        metrics = kwargs.get("metrics")
        if isinstance(metrics, dict) and isinstance(metrics.get("compaction"), dict):
            metrics["compaction"]["restorable"] = False
    return copied_messages


def _default_code_meta() -> dict[str, Any]:
    """Code Mode metadata for a plain chat thread."""
    return {
        "workspace_mode": "chat",
        "repo_key": None,
        "branch": None,
        "selected_sources": {},
    }


def _parse_code_meta(raw: Any) -> dict[str, Any]:
    """Parse one ``thread_code_meta`` hash value (JSON) fail-soft.

    Anything missing or malformed degrades to the chat defaults —
    a thread predating Code Mode is a chat thread, never an error.
    """
    meta = _default_code_meta()
    if raw is None:
        return meta
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    try:
        parsed = json.loads(raw) if isinstance(raw, str) else raw
    except (ValueError, TypeError):
        return meta
    if not isinstance(parsed, dict):
        return meta
    if parsed.get("workspace_mode") in ("chat", "code"):
        meta["workspace_mode"] = parsed["workspace_mode"]
    if isinstance(parsed.get("repo_key"), str) and parsed["repo_key"]:
        meta["repo_key"] = parsed["repo_key"]
    if isinstance(parsed.get("branch"), str) and parsed["branch"]:
        meta["branch"] = parsed["branch"]
    if isinstance(parsed.get("selected_sources"), dict):
        meta["selected_sources"] = parsed["selected_sources"]
    return meta


def _field_explicitly_set(chat_request: Any, name: str) -> bool:
    """Whether the client actually supplied ``name`` on this request.

    ``ChatRequest.workspace_mode`` / ``execution_mode`` carry non-None
    defaults (``"chat"`` / ``"act"``) for backward compatibility, so
    the value alone cannot distinguish "client sent the default" from
    "client sent nothing" — ``model_fields_set`` can. Lightweight
    request doubles without it fall back to attribute presence.
    """
    fields_set = getattr(chat_request, "model_fields_set", None)
    if isinstance(fields_set, (set, frozenset)):
        return name in fields_set
    return getattr(chat_request, name, None) is not None


def _code_meta_from_request(chat_request: ChatRequest) -> dict[str, Any]:
    """Code Mode metadata carried by one chat request.

    ``source_scope`` doubles as the thread's ``selected_sources``:
    it is the client-visible selection of repos/sources the thread
    is scoped to.
    """
    return {
        "workspace_mode": getattr(chat_request, "workspace_mode", None) or "chat",
        "repo_key": getattr(chat_request, "repo_key", None),
        "branch": getattr(chat_request, "branch", None),
        "selected_sources": getattr(chat_request, "source_scope", None) or {},
    }


def _merged_code_meta(existing_raw: Any, chat_request: ChatRequest) -> dict[str, Any]:
    """Merge a request's Code Mode fields over previously stored meta.

    Follow-up turns commonly send only ``thread_id``; fields the
    client did not explicitly supply keep their stored values instead
    of being clobbered back to chat/null/empty (which made Code Mode
    threads vanish from the Code rail).
    """
    merged = _parse_code_meta(existing_raw)
    if _field_explicitly_set(chat_request, "workspace_mode"):
        merged["workspace_mode"] = (
            getattr(chat_request, "workspace_mode", None) or "chat"
        )
    if _field_explicitly_set(chat_request, "repo_key"):
        merged["repo_key"] = getattr(chat_request, "repo_key", None)
    if _field_explicitly_set(chat_request, "branch"):
        merged["branch"] = getattr(chat_request, "branch", None)
    if _field_explicitly_set(chat_request, "source_scope"):
        merged["selected_sources"] = (
            getattr(chat_request, "source_scope", None) or {}
        )
    return merged


async def _save_thread_code_meta(redis, tenant_id: str, thread_id: str, meta: dict) -> None:
    """Persist code meta in the ``thread_code_meta`` Redis hash.

    Written from the same code path that writes ``thread_projects`` /
    ``thread_timestamps`` on thread create/update, so the hash always
    reflects the latest request for the thread. The durable mirror is
    the Supabase ``thread_metadata`` table (migration 008).
    """
    await redis.hset(
        f"tenant:{tenant_id}:thread_code_meta", thread_id, json.dumps(meta)
    )


def _effective_tool_settings(chat_request: ChatRequest) -> dict:
    """tool_settings plus the Code Mode fields the orchestrator reads.

    The orchestrator / tool dispatch receive everything through
    ``tool_settings`` (AgentState), so the Phase 1 fields are merged
    in here — explicitly-set request fields win over anything the
    client put in the raw tool_settings dict.
    """
    ts = dict(chat_request.tool_settings or {})
    # getattr throughout: lightweight request doubles (SimpleNamespace
    # in tests) may not carry the Code Mode fields at all.
    # workspace_mode / execution_mode only override tool_settings when
    # the client explicitly supplied them: their model defaults
    # ("chat" / "act") must not silently downgrade a plan/code mode
    # the client set through tool_settings alone.
    if _field_explicitly_set(chat_request, "workspace_mode"):
        ts["workspace_mode"] = getattr(chat_request, "workspace_mode", None) or "chat"
    elif "workspace_mode" not in ts:
        ts["workspace_mode"] = "chat"
    if _field_explicitly_set(chat_request, "execution_mode"):
        ts["execution_mode"] = getattr(chat_request, "execution_mode", None) or "act"
    elif "execution_mode" not in ts:
        ts["execution_mode"] = "act"
    if getattr(chat_request, "repo_key", None) is not None:
        ts["repo_key"] = chat_request.repo_key
    if getattr(chat_request, "branch", None) is not None:
        ts["branch"] = chat_request.branch
    if getattr(chat_request, "thinking_level", None) is not None:
        ts["thinking_level"] = chat_request.thinking_level
    if getattr(chat_request, "autonomy_mode", None) is not None:
        ts["sandbox_autonomy_mode"] = chat_request.autonomy_mode
    if getattr(chat_request, "source_scope", None) is not None:
        ts["source_scope"] = chat_request.source_scope
    if getattr(chat_request, "custom_system_prompt", None):
        ts["custom_system_prompt"] = chat_request.custom_system_prompt
    return ts


def _build_thread_list(
    threads, titles, pinned, archived, projects, timestamps, code_meta=None
):
    thread_list = []
    for t in threads:
        tid = t.decode("utf-8")
        title = titles.get(t, b"").decode("utf-8") or "New Chat"
        try:
            ts = float(timestamps.get(t, b"0").decode("utf-8"))
        except ValueError:
            ts = 0.0
        meta = _parse_code_meta((code_meta or {}).get(t))
        thread_list.append(
            {
                "thread_id": tid,
                "title": title,
                "is_pinned": t in pinned,
                "is_archived": t in archived,
                "project_id": projects.get(t, b"").decode("utf-8") or None,
                "workspace_mode": meta["workspace_mode"],
                "repo_key": meta["repo_key"],
                "branch": meta["branch"],
                "selected_sources": meta["selected_sources"],
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
        if message.reasoning:
            message_kwargs["reasoning_content"] = message.reasoning
        if message.reasoning_duration_seconds is not None:
            message_kwargs["reasoning_duration_seconds"] = (
                message.reasoning_duration_seconds
            )
        message_type = HumanMessage if message.role == "user" else AIMessage
        imported.append(
            message_type(
                content=message.content,
                id=message.id,
                additional_kwargs=message_kwargs,
            )
        )
    return imported


def _record_reasoning_event(
    event: dict,
    reasoning_parts: list[str],
    reasoning_duration_seconds: float | None,
) -> float | None:
    """Accumulate the streamed reasoning trace for one turn.

    Returns the updated duration (the end event may arrive after earlier
    chunks, and a failed stream keeps whatever was captured so far).
    """
    event_type = event.get("event")
    data = event.get("data") or {}
    if event_type == "on_reasoning_stream":
        text = data.get("text")
        if isinstance(text, str) and text:
            reasoning_parts.append(text)
    elif event_type == "on_reasoning_end":
        seconds = data.get("seconds")
        if isinstance(seconds, (int, float)) and not isinstance(seconds, bool):
            return float(seconds)
    return reasoning_duration_seconds


async def _stream_events(
    chat_request, tenant_id, thread_id, api_key_override, title_task, redis
):
    activity: list[dict] = []
    reasoning_parts: list[str] = []
    reasoning_duration_seconds: float | None = None
    turn_id = str(uuid.uuid4())
    async with _get_thread_mutation_lock(thread_id):
        _active_thread_generations.add(thread_id)
    try:
        yield f"data: {json.dumps({'event': 'metadata', 'data': {'thread_id': thread_id}})}\n\n"
        ts = _effective_tool_settings(chat_request)

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
            reasoning_duration_seconds = _record_reasoning_event(
                event, reasoning_parts, reasoning_duration_seconds
            )

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
        files_changed = await _collect_turn_files_changed(
            tenant_id, thread_id, ts, turn_id
        )
        if files_changed:
            yield f"data: {json.dumps({'type': 'files_changed', **files_changed})}\n\n"
        await _save_activity_history(
            redis,
            tenant_id,
            thread_id,
            activity,
            reasoning="".join(reasoning_parts) or None,
            reasoning_duration_seconds=reasoning_duration_seconds,
            files_changed=files_changed,
        )
        yield "data: [DONE]\n\n"
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.exception("Error in streaming")
        _fail_activity(activity)
        try:
            await _save_activity_history(
                redis,
                tenant_id,
                thread_id,
                activity,
                reasoning="".join(reasoning_parts) or None,
                reasoning_duration_seconds=reasoning_duration_seconds,
            )
        except Exception as save_error:
            sentry_sdk.capture_exception(save_error)
            logger.exception("Error saving activity after stream failure")
        yield f"data: {json.dumps({'error': _friendly_provider_error(e)})}\n\n"
        yield "data: [DONE]\n\n"
    finally:
        _active_thread_generations.discard(thread_id)


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

    @app_router.post("/api/chat/confirm-tool")
    async def confirm_tool(
        payload: ConfirmToolRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Approve or reject a gated external tool call.

        The chat dispatch gate (tool_dispatch) refuses mutating
        external tools (GitHub writes, non-GET OpenAPI operations) and
        surfaces a ``tool_confirmation_required`` payload instead. This
        endpoint is the human decision point: on approve it re-executes
        exactly that one tool call once, with the confirmation flag
        set; on reject it executes nothing. The result is returned to
        the caller directly — it is not re-injected into the finished
        LangGraph turn (documented limitation).
        """
        from backend.mcp_server.tool_dispatch import (
            _tool_requires_confirmation,
            execute_tools_internal,
        )

        if not payload.approve:
            return {"status": "rejected", "tool_name": payload.tool_name}
        gated = _tool_requires_confirmation(payload.tool_name)
        if not gated and payload.tool_name.startswith("api__"):
            from backend.services.openapi_importer import (
                openapi_requires_confirmation,
            )

            gated = await openapi_requires_confirmation(
                tenant_id, payload.tool_name
            )
        if not gated:
            raise HTTPException(
                status_code=400,
                detail="Tool does not require confirmation or is unknown",
            )
        context_str, _merged = await execute_tools_internal(
            [{"name": payload.tool_name, "args": payload.args, "confirmed": True}],
            tenant_id,
            {"confirmed_tool_names": [payload.tool_name]},
        )
        return {
            "status": "executed",
            "tool_name": payload.tool_name,
            "result": context_str,
        }

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
                # Serialize read-merge-write per thread so overlapping
                # requests cannot clobber each other's Code Mode fields.
                async with _get_thread_mutation_lock(thread_id):
                    # Fail-soft: a Redis double without hget (unit-test
                    # fakes) simply means "no stored meta to merge".
                    _hget = getattr(request.app.state.redis, "hget", None)
                    existing_meta_raw = (
                        await _hget(
                            f"tenant:{tenant_id}:thread_code_meta", thread_id
                        )
                        if _hget is not None
                        else None
                    )
                    merged_meta = _merged_code_meta(existing_meta_raw, chat_request)
                    # Hydrate omitted Code Mode fields from the stored
                    # meta so a follow-up turn that only repeats the
                    # thread_id still runs in the thread's workspace,
                    # without overriding explicit tool_settings values.
                    if existing_meta_raw is not None:
                        raw_ts = chat_request.tool_settings or {}
                        if (
                            not _field_explicitly_set(chat_request, "workspace_mode")
                            and "workspace_mode" not in raw_ts
                        ):
                            chat_request.workspace_mode = merged_meta["workspace_mode"]
                        if (
                            not _field_explicitly_set(chat_request, "repo_key")
                            and "repo_key" not in raw_ts
                        ):
                            chat_request.repo_key = merged_meta["repo_key"]
                        if (
                            not _field_explicitly_set(chat_request, "branch")
                            and "branch" not in raw_ts
                        ):
                            chat_request.branch = merged_meta["branch"]
                        if (
                            not _field_explicitly_set(chat_request, "source_scope")
                            and "source_scope" not in raw_ts
                        ):
                            chat_request.source_scope = (
                                merged_meta["selected_sources"] or None
                            )
                    await _save_thread_code_meta(
                        request.app.state.redis,
                        tenant_id,
                        thread_id,
                        merged_meta,
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
            # Inject custom_system_prompt + Code Mode fields into tool_settings
            ts = _effective_tool_settings(chat_request)

            async with _get_thread_mutation_lock(thread_id):
                _active_thread_generations.add(thread_id)
            try:
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
            finally:
                _active_thread_generations.discard(thread_id)
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
            raise HTTPException(status_code=504, detail="Request timeout. Please try again later.")
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error processing question")
            raise HTTPException(
                status_code=500,
                detail=_friendly_provider_error(e),
            )

    @app_router.get("/api/chat/threads")
    async def list_threads(
        request: Request,
        workspace_mode: str | None = None,
        repo_key: str | None = None,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Returns a list of all thread IDs belonging to the tenant.

        ``workspace_mode`` ('chat' / 'code') and ``repo_key`` query
        params optionally filter by the thread's Code Mode metadata.
        """
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
                code_meta,
            ) = await asyncio.gather(
                request.app.state.redis.smembers(f"tenant:{tenant_id}:threads"),
                request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_titles"),
                request.app.state.redis.smembers(f"tenant:{tenant_id}:pinned_threads"),
                request.app.state.redis.smembers(f"tenant:{tenant_id}:archived_threads"),
                request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_projects"),
                request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_timestamps"),
                request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_code_meta"),
            )
            thread_list = _build_thread_list(
                threads, titles, pinned, archived, projects, timestamps, code_meta
            )
            if workspace_mode is not None:
                thread_list = [
                    t for t in thread_list if t["workspace_mode"] == workspace_mode
                ]
            if repo_key is not None:
                thread_list = [
                    t for t in thread_list if t["repo_key"] == repo_key
                ]
            return {"threads": thread_list}
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error listing threads")
            raise HTTPException(
                status_code=500,
                detail="Internal server error. Please try again later.",
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
            reasoning_history: list[dict | None] = []
            files_changed_history: list[dict | None] = []
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
                        reasoning_history = [
                            {
                                "reasoning": item.get("reasoning"),
                                "reasoning_duration_seconds": item.get(
                                    "reasoning_duration_seconds"
                                ),
                            }
                            if isinstance(item, dict)
                            else None
                            for item in decoded
                            if isinstance(item, (dict, list))
                        ]
                        files_changed_history = [
                            item.get("files_changed")
                            if isinstance(item, dict)
                            else None
                            for item in decoded
                            if isinstance(item, (dict, list))
                        ]
                        response_times = [
                            item.get("response_at") if isinstance(item, dict) else None
                            for item in decoded
                            if isinstance(item, (dict, list))
                        ]
                        assistant_messages = [
                            message
                            for message in raw_messages
                            if message.__class__.__name__ == "AIMessage"
                            and not getattr(message, "tool_calls", None)
                        ]
                        if assistant_messages and response_times:
                            for message, response_at in zip(
                                assistant_messages[-len(response_times) :],
                                response_times[-len(assistant_messages) :],
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
                    raw_messages,
                    feedback_dict,
                    activity_history,
                    reasoning_history=reasoning_history,
                    files_changed_history=files_changed_history,
                )
            }
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception(f"Error fetching thread {thread_id}")
            raise HTTPException(
                status_code=500,
                detail="Internal server error. Please try again later.",
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
                detail="Internal server error. Please try again later.",
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
                detail="Internal server error. Please try again later.",
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
                detail="Internal server error. Please try again later.",
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
            saver_ctx: Any
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
                detail="Internal server error. Please try again later.",
            )

    async def _compaction_saver(request: Request, tenant_id: str, thread_id: str):
        """Ownership check + checkpointer saver for the compaction
        endpoints (same pattern as edit_message). Server threads only:
        local-guest threads live on-device and have no server state."""
        if tenant_id == "local_guest":
            raise HTTPException(
                status_code=400,
                detail="Compaction is available for synced conversations only.",
            )
        is_owner = await request.app.state.redis.sismember(
            f"tenant:{tenant_id}:threads", thread_id
        )
        if not is_owner:
            raise HTTPException(status_code=404, detail="Thread not found")
        from backend.config import get_config as _get_config

        config_obj = _get_config()
        saver_ctx: Any
        if config_obj.postgres_url:
            from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

            saver_ctx = AsyncPostgresSaver.from_conn_string(config_obj.postgres_url)
        else:
            from langgraph.checkpoint.redis.aio import AsyncRedisSaver

            saver_ctx = AsyncRedisSaver.from_conn_string(config_obj.redis_url)
        return config_obj, saver_ctx

    async def _replace_thread_messages(memory, thread_id: str, new_messages: list):
        """Replace a thread's full message list in the checkpointer."""
        from langchain_core.messages import RemoveMessage
        from langgraph.graph.message import REMOVE_ALL_MESSAGES

        from backend.mcp_server.orchestrator import _get_workflow

        workflow = _get_workflow()
        app = workflow.compile(checkpointer=memory)
        await app.aupdate_state(
            {"configurable": {"thread_id": thread_id}},
            {"messages": [RemoveMessage(id=REMOVE_ALL_MESSAGES), *new_messages]},
        )

    @app_router.post("/api/chat/threads/{thread_id}/compact/preview")
    async def compact_preview(
        thread_id: str,
        payload: CompactPreviewRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Generate a compaction summary WITHOUT applying anything."""
        from backend.mcp_server.compaction import (
            CompactionError,
            apply_compaction,
            check_minimum_progress,
            count_messages_tokens,
            generate_summary,
            split_for_compaction,
        )

        try:
            config_obj, saver_ctx = await _compaction_saver(
                request, tenant_id, thread_id
            )
            async with saver_ctx as memory:
                if config_obj.postgres_url:
                    await setup_postgres_checkpointer_once(
                        memory, config_obj.postgres_url
                    )
                state = await memory.aget_tuple(
                    {"configurable": {"thread_id": thread_id}}
                )
                if not state:
                    raise HTTPException(status_code=404, detail="Thread not found")
                raw_messages = state.checkpoint.get("channel_values", {}).get(
                    "messages", []
                )
                _, prefix, _ = split_for_compaction(
                    raw_messages, payload.keep_recent_turns
                )
                if not prefix:
                    raise HTTPException(
                        status_code=400,
                        detail="Nothing old enough to compact yet.",
                    )
                if not payload.model or not payload.api_key:
                    raise HTTPException(
                        status_code=403,
                        detail="You must provide your own LLM API key. "
                        "Add your key in Settings → API Keys.",
                    )
                tokens_before = count_messages_tokens(raw_messages, payload.model)
                try:
                    summary = await generate_summary(
                        prefix,
                        payload.model,
                        payload.api_key,
                        payload.base_url,
                        focus=payload.focus,
                    )
                    new_messages = apply_compaction(
                        raw_messages,
                        summary,
                        payload.keep_recent_turns,
                        tokens_before,
                    )
                    tokens_after = count_messages_tokens(new_messages, payload.model)
                    check_minimum_progress(tokens_before, tokens_after)
                except CompactionError as e:
                    raise HTTPException(status_code=400, detail=str(e))
                return {
                    "summary": summary,
                    "messages_compacted": len(prefix),
                    "tokens_before": tokens_before,
                    "tokens_after_estimate": tokens_after,
                }
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error generating compaction preview")
            raise HTTPException(
                status_code=502,
                detail="The model could not generate a summary. "
                "Nothing was changed.",
            )

    @app_router.post("/api/chat/threads/{thread_id}/compact/apply")
    async def compact_apply(
        thread_id: str,
        payload: CompactApplyRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Apply a user-accepted (possibly edited) compaction summary."""
        try:
            config_obj, saver_ctx = await _compaction_saver(
                request, tenant_id, thread_id
            )
            _ensure_thread_not_generating(thread_id)
            async with _get_thread_mutation_lock(thread_id):
                _ensure_thread_not_generating(thread_id)
                async with saver_ctx as memory:
                    if config_obj.postgres_url:
                        await setup_postgres_checkpointer_once(
                            memory, config_obj.postgres_url
                        )
                    return await _apply_compaction_tx(
                        memory,
                        _replace_thread_messages,
                        request.app.state.redis,
                        tenant_id,
                        thread_id,
                        payload,
                    )
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error applying compaction")
            raise HTTPException(
                status_code=500,
                detail="Internal server error. Please try again later.",
            )

    @app_router.post("/api/chat/threads/{thread_id}/compact/restore")
    async def compact_restore(
        thread_id: str,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Undo the latest compaction: roll the thread back to the
        checkpoint just before it was applied. Messages sent after
        the compaction are removed — the app warns about exactly
        that before calling this. Prior checkpoints are retained by
        the checkpointer, so the pre-compaction state is recovered
        verbatim, never reconstructed."""
        try:
            config_obj, saver_ctx = await _compaction_saver(
                request, tenant_id, thread_id
            )
            _ensure_thread_not_generating(thread_id)
            async with _get_thread_mutation_lock(thread_id):
                _ensure_thread_not_generating(thread_id)
                async with saver_ctx as memory:
                    if config_obj.postgres_url:
                        await setup_postgres_checkpointer_once(
                            memory, config_obj.postgres_url
                        )
                    return await _restore_compaction_tx(
                        memory,
                        _replace_thread_messages,
                        request.app.state.redis,
                        tenant_id,
                        thread_id,
                    )
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error restoring compaction")
            raise HTTPException(
                status_code=500,
                detail="Internal server error. Please try again later.",
            )

    @app_router.post("/api/chat/threads/{thread_id}/clear-tool-results")
    async def clear_tool_results(
        thread_id: str,
        payload: ClearToolResultsRequest,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        """Stage 0: replace old tool-result bodies with placeholders.

        Deterministic, no LLM call — the cheap context-recovery step
        that runs before summarization is even considered."""
        try:
            config_obj, saver_ctx = await _compaction_saver(
                request, tenant_id, thread_id
            )
            _ensure_thread_not_generating(thread_id)
            async with _get_thread_mutation_lock(thread_id):
                _ensure_thread_not_generating(thread_id)
                async with saver_ctx as memory:
                    if config_obj.postgres_url:
                        await setup_postgres_checkpointer_once(
                            memory, config_obj.postgres_url
                        )
                    return await _clear_tool_results_tx(
                        memory,
                        _replace_thread_messages,
                        thread_id,
                        payload,
                    )
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.exception("Error clearing tool results")
            raise HTTPException(
                status_code=500,
                detail="Internal server error. Please try again later.",
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
            request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_code_meta", thread_id),
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
            request.app.state.redis.delete(f"tenant:{tenant_id}:thread_code_meta"),
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
                            copied_messages = _prepare_duplicated_messages(raw_messages)
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
