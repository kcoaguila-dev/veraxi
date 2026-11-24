"""Manual live smoke-test for Veraxi thinking levels against real cloud/local endpoints.

Usage:
    backend/.venv/bin/python backend/scripts/verify_thinking_live.py \
        --model gpt-5.4 --level high
    backend/.venv/bin/python backend/scripts/verify_thinking_live.py \
        --model qwen3:8b --level on --base-url http://localhost:11434/v1
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time

from langchain_core.messages import HumanMessage

from backend.mcp_server.orchestrator import _create_chat_llm
from backend.mcp_server.think_parser import ThinkTagStreamParser
from backend.thinking_policy import (
    UnsupportedThinkingLevelError,
    probe_local_runtime,
    resolve_thinking_capability,
)


async def _run(model: str, level: str | None, base_url: str | None, api_key: str | None) -> int:
    probe = None
    if base_url:
        probe = await probe_local_runtime(base_url, [model], force_refresh=True)
        print(f"[local probe] runtime={probe.runtime}")

    cap = resolve_thinking_capability(model, base_url=base_url, runtime_probe=probe)
    print(f"[capability] {cap.to_dict()}")

    try:
        llm = _create_chat_llm(
            model_name=model,
            api_key=api_key,
            base_url=base_url,
            thinking_level=level,
        )
    except UnsupportedThinkingLevelError as exc:
        print(f"[FAIL-FAST] {exc}", file=sys.stderr)
        return 2

    print(f"[dispatch] model={llm.model} temp={llm.temperature} model_kwargs={llm.model_kwargs}")
    parser = ThinkTagStreamParser()
    reasoning_chars = 0
    content_buf: list[str] = []
    started = time.perf_counter()

    async for chunk in llm.astream([HumanMessage(content="What is 17 * 23? Think briefly.")]):
        r_kw = (getattr(chunk, "additional_kwargs", None) or {}).get("reasoning_content")
        if r_kw:
            res = parser.feed_explicit_reasoning(r_kw)
            reasoning_chars += sum(len(d) for d in res.reasoning_deltas)
        txt = getattr(chunk, "content", None)
        if isinstance(txt, str) and txt:
            res = parser.feed_content(txt)
            reasoning_chars += sum(len(d) for d in res.reasoning_deltas)
            content_buf.extend(res.content_deltas)

    tail = parser.flush()
    reasoning_chars += sum(len(d) for d in tail.reasoning_deltas)
    content_buf.extend(tail.content_deltas)

    elapsed = round(time.perf_counter() - started, 2)
    print(f"[result] elapsed={elapsed}s reasoning_chars={reasoning_chars}")
    print(f"[answer] {''.join(content_buf).strip()}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify Veraxi thinking levels live.")
    ap.add_argument("--model", required=True)
    ap.add_argument("--level", default=None)
    ap.add_argument("--base-url", default=None)
    ap.add_argument("--api-key", default=None)
    args = ap.parse_args()
    return asyncio.run(_run(args.model, args.level, args.base_url, args.api_key))


if __name__ == "__main__":
    raise SystemExit(main())
