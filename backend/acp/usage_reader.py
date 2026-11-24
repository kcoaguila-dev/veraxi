"""Read-only local Antigravity usage telemetry reader.

Reads local conversation metadata from ``ANTIGRAVITY_DATA_DIR`` (defaulting
to ``~/.gemini/antigravity-cli/conversations``) on a best-effort basis.
Never fabricates a remaining quota percentage when the upstream CLI does
not expose one.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import sentry_sdk


def resolve_antigravity_data_dir(configured_dir: str = "") -> Path:
    """Return the Antigravity conversations directory."""
    override = configured_dir or os.environ.get("ANTIGRAVITY_DATA_DIR", "")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".gemini" / "antigravity-cli" / "conversations"


def read_local_usage_summary(configured_dir: str = "") -> dict[str, Any]:
    """Return a fail-soft summary of local Antigravity conversation counts and tokens."""
    data_dir = resolve_antigravity_data_dir(configured_dir)
    if not data_dir.exists() or not data_dir.is_dir():
        return {
            "available": False,
            "data_dir": str(data_dir),
            "conversation_count": 0,
            "total_tokens": None,
            "quota_remaining_pct": None,
        }

    conversation_count = 0
    total_tokens = 0
    saw_tokens = False

    try:
        for entry in data_dir.iterdir():
            if entry.suffix not in (".json", ".jsonl"):
                continue
            conversation_count += 1
            if entry.suffix == ".json":
                tokens = _extract_tokens_from_json(entry)
                if tokens is not None:
                    total_tokens += tokens
                    saw_tokens = True
    except OSError as exc:
        sentry_sdk.capture_exception(exc)

    return {
        "available": True,
        "data_dir": str(data_dir),
        "conversation_count": conversation_count,
        "total_tokens": total_tokens if saw_tokens else None,
        "quota_remaining_pct": None,
    }


def _extract_tokens_from_json(path: Path) -> int | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    usage = data.get("usage") or data.get("total_usage")
    if isinstance(usage, dict):
        total = usage.get("total_tokens")
        if isinstance(total, int):
            return total
    return None
