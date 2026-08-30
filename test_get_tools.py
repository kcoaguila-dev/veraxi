import asyncio
from backend.mcp_server.llm_loop import get_tools

async def main():
    tools = await get_tools(None)
    names = [t["function"]["name"] for t in tools]
    print("Tools with None:", names)
    
    tools = await get_tools({"file_search_enabled": False})
    names = [t["function"]["name"] for t in tools]
    print("Tools with False:", names)

asyncio.run(main())
