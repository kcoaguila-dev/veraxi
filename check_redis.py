import asyncio
import redis.asyncio as redis
import os

async def main():
    redis_url = "rediss://default:gQAAAAAAARRkAAIgcDE1YWI4N2U3NDM1ZTE0NGZmYTAyMTljZjNkZmE1MzgyYg@summary-wahoo-70756.upstash.io:6379"
    client = redis.from_url(redis_url)
    keys = await client.keys("tenant:*")
    print(keys)

asyncio.run(main())
