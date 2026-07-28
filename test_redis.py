import asyncio
from backend.mcp_server.storage.redis_client import get_redis_client
from langchain_community.chat_message_histories import RedisChatMessageHistory

async def main():
    redis = await get_redis_client()
    threads = await redis.smembers("tenant:default:threads")
    for t in threads:
        tid = t.decode("utf-8")
        history = RedisChatMessageHistory(tid, url="redis://localhost:6379")
        for m in history.messages:
            if m.type == "ai":
                print(f"Thread {tid}, AI Msg: {m.additional_kwargs}")
        break

asyncio.run(main())
