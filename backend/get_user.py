import asyncio
from backend.config import get_config
import redis.asyncio as redis

async def check():
    config = get_config()
    client = redis.from_url(config.redis_url)
    keys = await client.keys("*")
    print(keys)
    await client.aclose()

asyncio.run(check())
