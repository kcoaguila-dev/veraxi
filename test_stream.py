import asyncio
import os
import sys

# Ensure backend directory is in path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), 'backend')))

os.environ["VERAXI_LLM_MODEL"] = "gemini-2.5-flash-lite"
os.environ["VERAXI_LLM_API_KEY"] = "fake-key"
os.environ["REDIS_URL"] = "redis://localhost:6379"

from backend.mcp_server.llm_loop import _get_workflow
from langchain_core.messages import HumanMessage

async def test():
    workflow = _get_workflow()
    app = workflow.compile()
    
    initial_state = {
        "messages": [HumanMessage(content="what is the current time?")],
        "tenant_id": "default",
        "context_relevance": "",
        "retrieved_context": "",
        "query_embedding": None,
        "calculate_grounding": False,
        "tool_settings": None,
    }
    
    async for event in app.astream_events(initial_state, version="v2"):
        if event["event"] in ["on_chain_end", "on_chain_start"]:
            print(f"{event['event']}: {event.get('name')}")

asyncio.run(test())
