import asyncio
from langchain_core.messages import AIMessage

async def main():
    m = AIMessage(content="", tool_calls=[{"name": "my_tool", "args": {"foo": "bar"}, "id": "123"}])
    print(m.tool_calls)

asyncio.run(main())
