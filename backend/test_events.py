import asyncio
from mcp_server.llm_loop import stream_answer_question

async def main():
    async for event in stream_answer_question("Search the web for Rockstar Games hack", is_temporary=True, model_override="gemini-2.5-flash-lite"):
        if event.get("event") not in ("on_chat_model_stream", "on_chat_model_start", "on_chat_model_end"):
            print(event.get("event"), event.get("name"), event.get("data", {}).keys())

asyncio.run(main())
