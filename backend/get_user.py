import asyncio

import redis.asyncio as redis

from backend.config import get_config


async def check():
    config = get_config()
    client = redis.from_url(config.redis_url)
    keys = await client.keys("*")
    print(keys)
    await client.aclose()

asyncio.run(check())
