import asyncio
from backend.mcp_server.llm_loop import stream_answer_question

async def test():
    events = []
    async for event in stream_answer_question("hello", tenant_id="local_personal_user", thread_id="test_thread_123"):
        events.append(event)
    for e in events:
        if e['event'] == 'on_chain_end':
            print("on_chain_end:", e['name'])

asyncio.run(test())
