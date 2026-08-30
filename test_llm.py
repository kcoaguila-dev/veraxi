import asyncio
from backend.mcp_server.llm_loop import get_tools

async def main():
    tools = await get_tools({"file_search_enabled": False})
    print("Tools when false:", tools)

asyncio.run(main())
