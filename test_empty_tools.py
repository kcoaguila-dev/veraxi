import asyncio
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage, AIMessage, ToolMessage

async def main():
    llm = ChatOpenAI(model="gpt-4o-mini", openai_api_key="sk-dummy", base_url="https://api.openai.com/v1")
    # Simulate a history with a tool call
    messages = [
        HumanMessage(content="Whos trump?"),
        AIMessage(content="", tool_calls=[{"name": "search_vectors", "args": {"query_text": "Trump"}, "id": "call_123"}]),
        ToolMessage(content="Donald Trump is a politician.", tool_call_id="call_123"),
        HumanMessage(content="Whos trump?")
    ]
    # Bind empty tools
    bound = llm.bind_tools([])
    print("Kwargs:", bound.kwargs)

asyncio.run(main())
