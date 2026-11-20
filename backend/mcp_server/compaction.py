"""Manual, user-approved context compaction for chat threads.

Design rules (from the rival/OSS review, 2026-11-20):

- **Never silent, never automatic.** A preview is generated first;
  nothing is applied until the user accepts (possibly edited) —
  Cline's user-accepts step, and the opposite of Claude Code's
  silent auto-compact, the most complained-about behaviour in this
  space.
- **Validate the summary.** A summary that is empty *or truncated
  mid-generation* must never replace history (Cline issue #14732:
  a truncated summary passed a non-empty check and silently
  replaced a full history). Truncation is detected via the
  provider's finish reason / the bound max_tokens.
- **Minimum progress gate** (OpenHands): refuse when compaction
  would forget less than ~10% of the current context.
- **Tool-pair-safe cuts.** The cut always lands on a HumanMessage
  boundary, so an AIMessage's tool calls are never separated from
  their ToolMessages (LangChain ``trim_messages`` semantics).
- **Originals are not destroyed by this module's data model:** the
  summary message carries a ``compaction`` record in its metrics
  (count + timestamp) and LangGraph checkpoints retain prior state
  versions; the UI renders the summary as a divider, not a bubble.
"""

from __future__ import annotations

import logging
from datetime import datetime, UTC
from collections.abc import Sequence

from langchain_core.messages import (
    BaseMessage,
    HumanMessage,
    SystemMessage,
    ToolMessage,
)

from backend.mcp_server.formatter import _segment_text, count_context_segments

logger = logging.getLogger(__name__)

SUMMARY_PREFIX = "[Conversation summary — earlier messages were compacted]"
CLEARED_TOOL_PLACEHOLDER = "[Tool result cleared to free context]"
MIN_PROGRESS_FRACTION = 0.10
SUMMARY_MAX_TOKENS = 2048

_COMPACTION_SYSTEM_PROMPT = """You are compacting a conversation so it can continue in a smaller context window. Write a structured summary of the conversation so far with EXACTLY these sections:

## Goal
What the user is trying to achieve.

## Decisions
Decisions made, WITH their rationale. Include approaches that were tried and rejected, and why.

## User constraints & preferences
Every instruction, constraint, or preference the user stated, as a verbatim-style bullet list. Do not drop any — losing these is the most damaging compaction failure.

## Facts & evidence
Key facts established, including retrieved/ cited information with source titles where known.

## Work completed
What has actually been done so far (distinguish done from merely planned).

## Open tasks & next steps
What remains, in order.

Rules: be specific (names, numbers, file paths, values); never invent details not in the conversation; if the user gave a focus instruction, weight the summary toward it but still keep every user constraint."""


class CompactionError(Exception):
    """Raised for user-facing compaction failures (maps to 4xx/502)."""


def split_for_compaction(
    messages: Sequence[BaseMessage], keep_recent_turns: int
) -> tuple[list[BaseMessage], list[BaseMessage], list[BaseMessage]]:
    """Split history into (pinned, prefix, recent).

    ``pinned`` = leading SystemMessages (always retained).
    ``recent`` = the last ``keep_recent_turns`` human turns, starting
    exactly at a HumanMessage so tool call/result pairs never split.
    ``prefix`` = everything between — the part to summarize/clear.
    """
    pinned: list[BaseMessage] = []
    rest: list[BaseMessage] = []
    for message in messages:
        if not rest and getattr(message, "type", "") == "system":
            pinned.append(message)
        else:
            rest.append(message)
    human_indices = [
        i for i, m in enumerate(rest) if getattr(m, "type", "") == "human"
    ]
    if keep_recent_turns <= 0:
        return pinned, rest, []
    if len(human_indices) <= keep_recent_turns:
        return pinned, [], rest
    cut = human_indices[-keep_recent_turns]
    return pinned, rest[:cut], rest[cut:]


def count_messages_tokens(
    messages: Sequence[BaseMessage], model_name: str | None
) -> int | None:
    """Local token count of a message list (all segments summed)."""
    segments = count_context_segments(messages, None, model_name)
    if segments is None:
        return None
    return sum(segments.values())


def check_minimum_progress(before: int | None, after: int | None) -> None:
    """Refuse compaction that would forget < MIN_PROGRESS_FRACTION."""
    if before is None or after is None or before <= 0:
        return
    saved = before - after
    if saved < MIN_PROGRESS_FRACTION * before:
        raise CompactionError(
            "Compaction would only free "
            f"{saved} of {before} tokens (<10%) — not worth losing the detail."
        )


def build_summary_message(
    summary: str, messages_compacted: int, tokens_before: int | None
) -> HumanMessage:
    """The HumanMessage that replaces the compacted prefix.

    Carries the compaction record in ``additional_kwargs['metrics']``
    — the one channel ``_process_single_message`` passes through to
    history responses — so the app renders a divider and the usage
    aggregation can treat it as the context baseline marker.
    """
    record = {
        "messages_compacted": messages_compacted,
        "compacted_at": datetime.now(UTC).isoformat(),
        "tokens_before": tokens_before,
        # The checkpointer retains the pre-compaction checkpoint, so
        # this compaction can be undone via the restore endpoint;
        # the app shows its Restore action only when this is set.
        "restorable": True,
    }
    return HumanMessage(
        content=f"{SUMMARY_PREFIX}\n\n{summary.strip()}",
        additional_kwargs={"metrics": {"compaction": record}},
    )


def find_latest_compaction(
    messages: Sequence[BaseMessage],
) -> tuple[int, dict] | None:
    """Locate the newest compaction summary in a message list.

    Returns (index, record) or None. The record lives in the
    summary message's metrics — the same channel the app reads to
    render the divider.
    """
    for index in range(len(messages) - 1, -1, -1):
        message = messages[index]
        metrics = (getattr(message, "additional_kwargs", None) or {}).get(
            "metrics"
        )
        if isinstance(metrics, dict):
            record = metrics.get("compaction")
            if isinstance(record, dict):
                return index, record
    return None


def _carries_compaction(messages: Sequence[BaseMessage], compacted_at) -> bool:
    """True when a message list contains the summary of the
    compaction stamped [compacted_at]. Matching on the record's
    timestamp (unique per compaction) instead of message ids:
    ids are None until the graph's reducer assigns them, so they
    are not a reliable identity at every layer."""
    for message in messages:
        metrics = (getattr(message, "additional_kwargs", None) or {}).get(
            "metrics"
        )
        if isinstance(metrics, dict):
            record = metrics.get("compaction")
            if isinstance(record, dict) and record.get("compacted_at") == compacted_at:
                return True
    return False


def pick_pre_compaction_messages(
    history_message_lists: Sequence[Sequence[BaseMessage]],
    compacted_at,
) -> list[BaseMessage] | None:
    """From checkpoint message lists (newest first), the state just
    before the compaction stamped [compacted_at] was originally
    applied.

    Searching after the *oldest* checkpoint carrying [compacted_at]
    handles C1 -> C2 -> restore C2 -> restore C1: the intermediate C2
    checkpoint replaced C1's summary so it lacks [compacted_at], yet
    it is newer than the original C1 transition and must be skipped.
    """
    if compacted_at is None:
        return None
    carrying_indices = [
        i
        for i, messages in enumerate(history_message_lists)
        if _carries_compaction(messages, compacted_at)
    ]
    start = carrying_indices[-1] + 1 if carrying_indices else 0
    for messages in history_message_lists[start:]:
        if not _carries_compaction(messages, compacted_at):
            return list(messages)
    return None


def apply_compaction(
    messages: Sequence[BaseMessage],
    summary: str,
    keep_recent_turns: int,
    tokens_before: int | None,
) -> list[BaseMessage]:
    """New message list: pinned + summary + recent turns verbatim."""
    if not summary or not summary.strip():
        raise CompactionError("Summary is empty — nothing to apply.")
    pinned, prefix, recent = split_for_compaction(messages, keep_recent_turns)
    if not prefix:
        raise CompactionError("Nothing old enough to compact yet.")
    summary_message = build_summary_message(summary, len(prefix), tokens_before)
    return [*pinned, summary_message, *recent]


def clear_old_tool_results(
    messages: Sequence[BaseMessage], keep_recent_turns: int
) -> tuple[list[BaseMessage], int]:
    """Replace old ToolMessage bodies with a placeholder (Stage 0).

    Deterministic and LLM-free — the cheap stage that runs before
    summarization is even considered (LangChain's ContextEditing
    ordering; JetBrains' masking evidence). Returns the new list and
    how many tool results were cleared. Recent turns are untouched,
    and already-cleared results are skipped.
    """
    _, prefix, recent = split_for_compaction(messages, keep_recent_turns)
    pinned_count = len(messages) - len(prefix) - len(recent)
    cleared = 0
    new_prefix: list[BaseMessage] = []
    for message in prefix:
        if isinstance(message, ToolMessage) or getattr(message, "type", "") == "tool":
            text = _segment_text(message.content)
            if text and not text.startswith(CLEARED_TOOL_PLACEHOLDER):
                new_prefix.append(
                    ToolMessage(
                        content=(
                            f"{CLEARED_TOOL_PLACEHOLDER} "
                            f"(originally ~{len(text)} chars)"
                        ),
                        tool_call_id=getattr(message, "tool_call_id", ""),
                        id=getattr(message, "id", None),
                    )
                )
                cleared += 1
                continue
        new_prefix.append(message)
    return [*messages[:pinned_count], *new_prefix, *recent], cleared


def _transcript(prefix: Sequence[BaseMessage]) -> str:
    lines: list[str] = []
    for message in prefix:
        text = _segment_text(getattr(message, "content", ""))
        if not text:
            continue
        role = {
            "human": "User",
            "ai": "Assistant",
            "tool": "Tool result",
            "system": "System",
        }.get(getattr(message, "type", ""), "Message")
        lines.append(f"{role}: {text}")
    return "\n\n".join(lines)


async def generate_summary(
    prefix: Sequence[BaseMessage],
    model_name: str,
    api_key: str | None,
    base_url: str | None,
    focus: str | None = None,
) -> str:
    """Summarize the prefix with the thread's own model (BYOK).

    Raises CompactionError when the summary is empty or was
    truncated mid-generation — a truncated summary must never be
    applied (Cline #14732).
    """
    from backend.mcp_server.orchestrator import _create_chat_llm

    transcript = _transcript(prefix)
    if not transcript.strip():
        raise CompactionError("Nothing to summarize.")
    prompt = transcript
    if focus:
        prompt += f"\n\nFocus instruction from the user: {focus}"
    llm = _create_chat_llm(model_name, api_key, base_url)
    llm = llm.bind(max_tokens=SUMMARY_MAX_TOKENS)
    response = await llm.ainvoke(
        [
            SystemMessage(content=_COMPACTION_SYSTEM_PROMPT),
            HumanMessage(content=prompt),
        ]
    )
    text = _segment_text(getattr(response, "content", "")).strip()
    if not text:
        raise CompactionError("The model returned an empty summary.")
    metadata = getattr(response, "response_metadata", None) or {}
    finish_reason = str(
        metadata.get("finish_reason") or metadata.get("stop_reason") or ""
    ).lower()
    usage = getattr(response, "usage_metadata", None) or {}
    output_tokens = usage.get("output_tokens") if isinstance(usage, dict) else None
    if finish_reason in ("length", "max_tokens") or (
        isinstance(output_tokens, int) and output_tokens >= SUMMARY_MAX_TOKENS
    ):
        raise CompactionError(
            "The summary was cut off before it finished — try again, "
            "or compact fewer messages at once."
        )
    return text
