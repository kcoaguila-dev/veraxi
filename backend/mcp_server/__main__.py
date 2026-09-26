import asyncio

from backend.mcp_server.server import mcp_server
from mcp.server.stdio import stdio_server


async def main():
    """Run the MCP server via standard input/output for self-hosted desktop clients."""
    await mcp_server.run_stdio_async()


if __name__ == "__main__":
    asyncio.run(main())
