import pytest
from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

from backend.mcp_server.server import apply_mcp_profile


def get_test_server():
    server = MCPServer("test_server")

    @server.tool(name="mcp_merge_rank")
    def mcp_merge_rank() -> str:
        return ""

    @server.tool(name="mcp_ingest_knowledge")
    def mcp_ingest_knowledge() -> str:
        return ""

    @server.tool(name="mcp_something_else")
    def mcp_something_else() -> str:
        return ""

    @server.prompt(name="crag_orchestrator")
    def crag_orchestrator() -> str:
        return ""

    @server.prompt(name="ingest_knowledge")
    def ingest_knowledge() -> str:
        return ""

    return server


def test_agent_profile():
    server = get_test_server()
    apply_mcp_profile(server, "agent")

    tools = {t.name for t in server._tool_manager.list_tools()}
    prompts = {p.name for p in server._prompt_manager.list_prompts()}

    assert "mcp_merge_rank" in tools
    assert "mcp_ingest_knowledge" not in tools
    assert "mcp_something_else" not in tools

    assert "crag_orchestrator" in prompts
    assert "ingest_knowledge" not in prompts

    with pytest.raises(ToolError):
        server.remove_tool("non_existent")


def test_admin_profile():
    server = get_test_server()
    apply_mcp_profile(server, "admin")

    tools = {t.name for t in server._tool_manager.list_tools()}
    prompts = {p.name for p in server._prompt_manager.list_prompts()}

    assert "mcp_merge_rank" in tools
    assert "mcp_ingest_knowledge" in tools
    assert "mcp_something_else" in tools

    assert "crag_orchestrator" in prompts
    assert "ingest_knowledge" in prompts


def test_all_profile():
    server = get_test_server()
    apply_mcp_profile(server, "all")

    tools = {t.name for t in server._tool_manager.list_tools()}
    assert "mcp_merge_rank" in tools
    assert "mcp_ingest_knowledge" in tools


def test_real_agent_tools_exclude_web_search():
    from backend.mcp_server.server import AGENT_TOOLS

    assert "mcp_web_search" not in AGENT_TOOLS
    assert "mcp_ephemeral_web_rag" in AGENT_TOOLS
    assert "mcp_merge_rank" in AGENT_TOOLS
    assert "mcp_search_vectors" in AGENT_TOOLS
    assert "mcp_query_graph" in AGENT_TOOLS
    assert "mcp_agentic_debate" in AGENT_TOOLS
