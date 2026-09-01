from unittest.mock import AsyncMock, patch

import pytest
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage

from backend.mcp_server.llm_loop import _prepend_system_messages, call_model
from backend.prompts import CHAT_SYSTEM_PROMPT


def test_prepend_system_messages_injects_chat_prompt():
    messages = [HumanMessage(content="元気ですか？")]

    modified = _prepend_system_messages(messages)

    assert len(modified) == 2
    assert isinstance(modified[0], SystemMessage)
    assert modified[0].content == CHAT_SYSTEM_PROMPT
    assert modified[1].content == "元気ですか？"


def test_system_prompt_citation_format():
    """Verify that the system prompts strictly forbid parentheses around citations."""
    from backend.prompts import CHAT_SYSTEM_PROMPT, CRAG_ORCHESTRATOR_PROMPT
    
    assert "DO NOT wrap citations in parentheses" in CHAT_SYSTEM_PROMPT
    assert "DO NOT wrap citations in parentheses" in CRAG_ORCHESTRATOR_PROMPT
    assert "fact [Foxbusiness](url)" in CHAT_SYSTEM_PROMPT
    assert "fact [Foxbusiness](url)" in CRAG_ORCHESTRATOR_PROMPT

@pytest.mark.asyncio
@patch("backend.mcp_server.llm_loop.get_tools", new_callable=AsyncMock)
@patch("backend.mcp_server.llm_loop._create_chat_llm")
async def test_call_model_passes_language_system_prompt(mock_create_llm, mock_get_tools):
    mock_get_tools.return_value = []
    mock_instance = AsyncMock()
    mock_create_llm.return_value = mock_instance
    mock_instance.bind_tools.return_value = mock_instance

    captured_messages = []

    async def mock_invoke(messages):
        captured_messages.extend(messages)
        return AIMessage(content="元気です！あなたはどうですか？")

    mock_instance.ainvoke = AsyncMock(side_effect=mock_invoke)

    state = {
        "messages": [HumanMessage(content="元気ですか？")],
        "tenant_id": "test",
        "context_relevance": "",
        "retrieved_context": "",
        "calculate_grounding": False,
        "tool_settings": {},
    }

    result = await call_model(state)

    assert captured_messages
    assert isinstance(captured_messages[0], SystemMessage)
    assert "not transliteration (e.g., no romaji or pinyin)" in captured_messages[0].content
    assert result["messages"][0].content == "元気です！あなたはどうですか？"
