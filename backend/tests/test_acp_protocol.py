"""Unit tests for ACP JSON-RPC 2.0 protocol framing and Veraxi SSE translation."""

from backend.acp.protocol import (
    AcpTurnAdapter,
    build_friendly_acp_error,
    encode_rpc_request,
    encode_rpc_response,
    friendly_acp_exception_error,
    is_quota_exhausted_error,
    parse_ndjson_line,
)


def test_ndjson_round_trip():
    raw = encode_rpc_request("req-1", "session/prompt", {"sessionId": "s1"})
    assert raw.endswith(b"\n")
    parsed = parse_ndjson_line(raw)
    assert parsed == {
        "jsonrpc": "2.0",
        "id": "req-1",
        "method": "session/prompt",
        "params": {"sessionId": "s1"},
    }
    assert parse_ndjson_line(b"   \n") is None
    assert parse_ndjson_line(b"not-json") is None


def test_encode_rpc_response():
    raw = encode_rpc_response(42, result={"outcome": {"outcome": "selected", "optionId": "allow_once"}})
    parsed = parse_ndjson_line(raw)
    assert parsed["id"] == 42
    assert parsed["result"]["outcome"]["optionId"] == "allow_once"


def test_quota_error_classification():
    assert is_quota_exhausted_error("HTTP 429 RESOURCE_EXHAUSTED: usage limit reached")
    assert not is_quota_exhausted_error("SyntaxError in file")

    friendly = build_friendly_acp_error("429 Too Many Requests")
    assert friendly["code"] == "quota_exhausted"
    assert friendly["recoverable_action"] == "switch_model"


def test_friendly_acp_exception_error_redacts_internal_details():
    secret_exc = RuntimeError("/home/ubuntu/secret/path.py: Traceback (most recent call last)")
    safe = friendly_acp_exception_error(secret_exc)
    assert safe["code"] == "acp_error"
    assert "/home/ubuntu/secret/path.py" not in safe["error"]
    assert "Traceback" not in safe["error"]

    quota_json_exc = RuntimeError('{"code": 429, "message": "internal quota details /var/log"}')
    quota_safe = friendly_acp_exception_error(quota_json_exc)
    assert quota_safe["code"] == "quota_exhausted"
    assert quota_safe["recoverable_action"] == "switch_model"
    assert "/var/log" not in quota_safe["error"]


def test_turn_adapter_translates_thought_text_tools_and_permission():
    adapter = AcpTurnAdapter(veraxi_session_id="sess-1")

    thought_events = adapter.translate_notification(
        {
            "method": "session/update",
            "params": {
                "update": {
                    "sessionUpdate": "agent_thought_chunk",
                    "content": {"type": "text", "text": "Checking files..."},
                }
            },
        }
    )
    assert thought_events == [{"event": "on_reasoning_stream", "data": {"text": "Checking files..."}}]

    text_events = adapter.translate_notification(
        {
            "method": "session/update",
            "params": {
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "Here is the fix."},
                }
            },
        }
    )
    assert text_events[0]["event"] == "on_reasoning_end"
    assert text_events[1] == {
        "event": "on_chat_model_stream",
        "data": {"chunk": {"content": "Here is the fix."}},
    }

    tool_start = adapter.translate_notification(
        {
            "method": "session/update",
            "params": {
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "tc-1",
                    "title": "edit_file",
                    "rawInput": {"path": "foo.py"},
                }
            },
        }
    )
    assert tool_start[0]["event"] == "on_tool_start"
    assert tool_start[0]["run_id"] == "tc-1"

    tool_end = adapter.translate_notification(
        {
            "method": "session/update",
            "params": {
                "update": {
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "tc-1",
                    "status": "completed",
                    "rawOutput": "Updated foo.py",
                }
            },
        }
    )
    assert tool_end[0]["event"] == "on_tool_end"
    assert tool_end[0]["status"] == "success"

    perm = adapter.translate_permission_request(
        {
            "id": 99,
            "method": "session/request_permission",
            "params": {
                "description": "Write to foo.py",
                "toolCall": {"title": "edit_file", "rawInput": {"path": "foo.py"}},
                "options": [{"optionId": "allow_once", "name": "Allow Once"}],
            },
        }
    )
    assert perm["event"] == "acp_permission_request"
    assert perm["session_id"] == "sess-1"
    assert perm["request_id"] == "99"
    assert perm["tool_name"] == "edit_file"
