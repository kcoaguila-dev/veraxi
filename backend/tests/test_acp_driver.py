"""Tests for LocalAcpDriver subprocess lifecycle, env scrubbing, and permissions."""

import asyncio
import sys

import pytest

from backend.acp.driver import LocalAcpDriver, build_scrubbed_env

_MOCK_ACP_SCRIPT = """
import json, sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    method = msg.get("method")
    rid = msg.get("id")
    if method == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1}}), flush=True)
    elif method == "session/new":
        print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": "mock-acp-1"}}), flush=True)
    elif method == "session/prompt":
        print(json.dumps({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {"update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Thinking"}}},
        }), flush=True)
        print(json.dumps({
            "jsonrpc": "2.0",
            "id": "perm-1",
            "method": "session/request_permission",
            "params": {"description": "Run test", "toolCall": {"title": "run_command", "rawInput": {"cmd": "pytest"}}},
        }), flush=True)
        perm_reply = json.loads(sys.stdin.readline())
        outcome = perm_reply.get("result", {}).get("outcome", {}).get("outcome", "cancelled")
        print(json.dumps({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"Outcome:{outcome}"}}},
        }), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}}), flush=True)
"""


def test_build_scrubbed_env_drops_backend_secrets():
    raw = {
        "PATH": "/usr/bin",
        "HOME": "/home/user",
        "NEO4J_PASSWORD": "super-secret-db-password",
        "STRIPE_API_KEY": "sk_live_secret",
        "SUPABASE_SERVICE_KEY": "service-role-secret",
    }
    scrubbed = build_scrubbed_env(raw)
    assert scrubbed == {"PATH": "/usr/bin", "HOME": "/home/user"}


@pytest.mark.asyncio
async def test_local_acp_driver_streams_and_resolves_permission(tmp_path):
    async def mock_factory(*_args, **kwargs):
        return await asyncio.create_subprocess_exec(
            sys.executable,
            "-c",
            _MOCK_ACP_SCRIPT,
            stdin=kwargs["stdin"],
            stdout=kwargs["stdout"],
            stderr=kwargs["stderr"],
            cwd=kwargs["cwd"],
            env=kwargs["env"],
        )

    driver = LocalAcpDriver(binary="mock-agy", process_factory=mock_factory)
    events = []

    async def consume():
        async for evt in driver.stream_prompt(
            tenant_id="t-1",
            thread_id="th-1",
            prompt_text="Fix the bug",
            cwd=str(tmp_path),
        ):
            events.append(evt)
            if evt.get("event") == "acp_permission_request":
                resolved = await driver.resolve_permission(
                    evt["session_id"], evt["request_id"], "allow_once"
                )
                assert resolved is True

    await consume()

    event_types = [e.get("event") for e in events]
    assert "on_step_start" in event_types
    assert "on_reasoning_stream" in event_types
    assert "acp_permission_request" in event_types
    assert "on_chat_model_stream" in event_types
    chunks = [
        e["data"]["chunk"]["content"]
        for e in events
        if e.get("event") == "on_chat_model_stream"
    ]
    assert "".join(chunks) == "Outcome:selected"

    for sid in list(driver._sessions.keys()):
        await driver.close_session(sid)
