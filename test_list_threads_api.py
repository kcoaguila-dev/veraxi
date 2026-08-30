import asyncio
import redis.asyncio as redis

async def main():
    redis_url = "rediss://default:gQAAAAAAARRkAAIgcDE1YWI4N2U3NDM1ZTE0NGZmYTAyMTljZjNkZmE1MzgyYg@summary-wahoo-70756.upstash.io:6379"
    client = redis.from_url(redis_url)
    tenant_id = "2b0d4cab-503e-4827-91d6-5806e587b15f"
    
    threads = await client.smembers(f"tenant:{tenant_id}:threads")
    titles = await client.hgetall(f"tenant:{tenant_id}:thread_titles")
    pinned = await client.smembers(f"tenant:{tenant_id}:pinned_threads")
    archived = await client.smembers(f"tenant:{tenant_id}:archived_threads")
    projects = await client.hgetall(f"tenant:{tenant_id}:thread_projects")
    timestamps = await client.hgetall(f"tenant:{tenant_id}:thread_timestamps")
    
    thread_list = []
    for t in threads:
        tid = t.decode("utf-8")
        title = titles.get(t, b"").decode("utf-8")
        if not title:
            title = "New Chat"
        is_pinned = t in pinned
        is_archived = t in archived
        project_id = projects.get(t, b"").decode("utf-8")
        
        try:
            ts = float(timestamps.get(t, b"0").decode("utf-8"))
        except ValueError:
            ts = 0.0
            
        thread_list.append({
            "thread_id": tid, 
            "title": title,
            "is_pinned": is_pinned,
            "is_archived": is_archived,
            "project_id": project_id if project_id else None,
            "_timestamp": ts
        })
        
    thread_list.sort(key=lambda x: x["_timestamp"], reverse=True)
    for t in thread_list:
        del t["_timestamp"]
        
    print(thread_list)

asyncio.run(main())
