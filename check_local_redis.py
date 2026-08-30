import asyncio
import redis.asyncio as redis

async def main():
    redis_url = "redis://localhost:6379/0"
    client = redis.from_url(redis_url)
    keys = await client.keys("tenant:*")
    print(keys)

asyncio.run(main())
