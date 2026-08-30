import asyncio
import redis.asyncio as redis

async def main():
    redis_url = "rediss://default:gQAAAAAAARRkAAIgcDE1YWI4N2U3NDM1ZTE0NGZmYTAyMTljZjNkZmE1MzgyYg@summary-wahoo-70756.upstash.io:6379"
    client = redis.from_url(redis_url)
    titles = await client.hgetall("tenant:2b0d4cab-503e-4827-91d6-5806e587b15f:thread_titles")
    for k, v in titles.items():
        print(f"{k.decode()}: {v.decode()}")

asyncio.run(main())
