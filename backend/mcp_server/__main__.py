import asyncio
from mcp.server.stdio import stdio_server
from backend.mcp_server.server import mcp_server

async def main():
    """Run the MCP server via standard input/output for self-hosted desktop clients."""
    async with stdio_server() as (read_stream, write_stream):
        await mcp_server.run(
            read_stream, write_stream, mcp_server.create_initialization_options()
        )

if __name__ == "__main__":
    asyncio.run(main())
