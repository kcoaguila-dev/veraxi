"""Chunk-boundary-safe streaming parser for ``<think>`` / ``<thought>`` tags."""

from __future__ import annotations

import time
from dataclasses import dataclass

_OPEN_TAGS = ("<think>", "<thought>")
_CLOSE_TAGS = ("</think>", "</thought>")
_MAX_TAG_LEN = max(len(t) for t in (*_OPEN_TAGS, *_CLOSE_TAGS))


def _find_earliest_tag(text: str, tags: tuple[str, ...]) -> tuple[int, str] | None:
    best_idx = -1
    best_tag = ""
    for tag in tags:
        idx = text.find(tag)
        if idx != -1 and (best_idx == -1 or idx < best_idx):
            best_idx = idx
            best_tag = tag
    return (best_idx, best_tag) if best_idx != -1 else None


def _trailing_partial_tag_len(text: str, tags: tuple[str, ...]) -> int:
    """Return length of any trailing suffix that is a strict prefix of a tag."""
    max_check = min(len(text), _MAX_TAG_LEN - 1)
    for size in range(max_check, 0, -1):
        suffix = text[-size:]
        if any(tag.startswith(suffix) for tag in tags):
            return size
    return 0


@dataclass
class ThinkParseResult:
    """Events extracted from a single streamed text chunk."""

    reasoning_deltas: list[str]
    content_deltas: list[str]
    reasoning_ended_ms: int | None = None


class ThinkTagStreamParser:
    """Stateful parser separating inline reasoning tags from visible content."""

    def __init__(self) -> None:
        self.in_thinking: bool = False
        self._explicit_reasoning_active: bool = False
        self._thinking_start: float | None = None
        self._buffer: str = ""

    def _start_timer(self) -> None:
        if self._thinking_start is None:
            self._thinking_start = time.perf_counter()

    def _finish_timer_ms(self) -> int:
        if self._thinking_start is None:
            return 0
        dur = round((time.perf_counter() - self._thinking_start) * 1000)
        self._thinking_start = None
        return dur

    def feed_explicit_reasoning(self, text: str) -> ThinkParseResult:
        """Record an explicit ``reasoning_content`` delta from provider kwargs."""
        self._start_timer()
        self._explicit_reasoning_active = True
        return ThinkParseResult(reasoning_deltas=[text], content_deltas=[])

    def feed_content(self, text: str) -> ThinkParseResult:
        """Process a streamed ``chunk.content`` string across tag boundaries."""
        ended_ms: int | None = None
        if self._explicit_reasoning_active and not self.in_thinking and text:
            self._explicit_reasoning_active = False
            ended_ms = self._finish_timer_ms()

        reasoning_deltas: list[str] = []
        content_deltas: list[str] = []
        self._buffer += text

        while self._buffer:
            if self.in_thinking:
                found = _find_earliest_tag(self._buffer, _CLOSE_TAGS)
                if found is not None:
                    idx, tag = found
                    if idx > 0:
                        reasoning_deltas.append(self._buffer[:idx])
                    self._buffer = self._buffer[idx + len(tag) :]
                    self.in_thinking = False
                    ended_ms = self._finish_timer_ms()
                    continue

                hold = _trailing_partial_tag_len(self._buffer, _CLOSE_TAGS)
                emit_len = len(self._buffer) - hold
                if emit_len > 0:
                    reasoning_deltas.append(self._buffer[:emit_len])
                    self._buffer = self._buffer[emit_len:]
                break

            found_open = _find_earliest_tag(self._buffer, _OPEN_TAGS)
            if found_open is not None:
                idx, tag = found_open
                if idx > 0:
                    content_deltas.append(self._buffer[:idx])
                self._buffer = self._buffer[idx + len(tag) :]
                self.in_thinking = True
                self._start_timer()
                continue

            # Strip any dangling close tag emitted when thinking was disabled.
            found_dangling = _find_earliest_tag(self._buffer, _CLOSE_TAGS)
            if found_dangling is not None:
                idx, tag = found_dangling
                if idx > 0:
                    content_deltas.append(self._buffer[:idx])
                self._buffer = self._buffer[idx + len(tag) :]
                continue

            hold = _trailing_partial_tag_len(
                self._buffer, (*_OPEN_TAGS, *_CLOSE_TAGS)
            )
            emit_len = len(self._buffer) - hold
            if emit_len > 0:
                content_deltas.append(self._buffer[:emit_len])
                self._buffer = self._buffer[emit_len:]
            break

        return ThinkParseResult(
            reasoning_deltas=reasoning_deltas,
            content_deltas=content_deltas,
            reasoning_ended_ms=ended_ms,
        )

    def flush(self) -> ThinkParseResult:
        """Flush any buffered partial tag text at end of stream."""
        if not self._buffer:
            return ThinkParseResult(reasoning_deltas=[], content_deltas=[])
        leftover = self._buffer
        self._buffer = ""
        if self.in_thinking:
            self.in_thinking = False
            return ThinkParseResult(
                reasoning_deltas=[leftover],
                content_deltas=[],
                reasoning_ended_ms=self._finish_timer_ms(),
            )
        return ThinkParseResult(reasoning_deltas=[], content_deltas=[leftover])
