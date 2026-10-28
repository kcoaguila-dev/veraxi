from unittest.mock import AsyncMock, patch

import pytest
from langchain_core.messages import HumanMessage, SystemMessage

from backend.mcp_server.formatter import _prepend_system_messages
from backend.mcp_server.tool_dispatch import execute_tools_internal
from backend.prompts import CHAT_SYSTEM_PROMPT


def test_prepend_system_messages_with_custom_prompt():
    messages = [HumanMessage(content="Hello")]
    custom_prompt = "Speak like a pirate."

    modified = _prepend_system_messages(messages, custom_system_prompt=custom_prompt)

    assert len(modified) == 3
    assert isinstance(modified[0], SystemMessage)
    assert modified[0].content == CHAT_SYSTEM_PROMPT
    assert isinstance(modified[1], SystemMessage)
    assert "USER CUSTOM INSTRUCTIONS:\nSpeak like a pirate." in modified[1].content
    assert modified[2].content == "Hello"


def test_prepend_system_messages_without_custom_prompt():
    messages = [HumanMessage(content="hi")]
    modified = _prepend_system_messages(messages, custom_system_prompt=None)

    assert len(modified) == 2
    assert isinstance(modified[0], SystemMessage)
    assert modified[0].content == CHAT_SYSTEM_PROMPT
    assert modified[1].content == "hi"

    # Test with empty string
    modified_empty = _prepend_system_messages(messages, custom_system_prompt="   ")
    assert len(modified_empty) == 2


@pytest.mark.asyncio
@patch("backend.mcp_server.tool_dispatch._execute_mcp_tool", new_callable=AsyncMock)
@patch("backend.mcp_server.tool_dispatch._execute_single_tool")
async def test_execute_tools_internal_telemetry_isolation(
    mock_single_tool, mock_mcp_tool
):
    class MockMcpHit:
        def __init__(self):
            self.id = "mcp_1"
            self.payload = {"content": "AAPL is at $150"}
            self.sources = ["MCP Server (OpenBB)"]

    class MockVectorHit:
        def __init__(self):
            self.id = "vec_1"
            self.payload = {"text": "Apple is a tech company."}
            self.sources = ["vector_db"]
            self.score = 0.9

    mock_mcp_tool.return_value = ([MockMcpHit()], [])
    mock_single_tool.return_value = ([MockVectorHit()], [])

    tool_calls = [
        {"name": "mcp__openbb__quote", "args": {"ticker": "AAPL"}},
        {"name": "search_vectors", "args": {"query": "Apple info"}}
    ]

    context_str, _merged = await execute_tools_internal(
        tool_calls, "test_tenant", {}
    )

    assert "[EXTERNAL TELEMETRY & ACTIONS]" in context_str
    assert "AAPL is at $150" in context_str
    assert "[GROUNDED KNOWLEDGE GRAPH & VECTOR CONTEXT]" in context_str
    assert "Apple is a tech company." in context_str
