import asyncio

import redis.asyncio as redis

from backend.config import get_config


async def migrate_tenant_data(old_tenant: str, new_tenant: str):
    config = get_config()
    client = redis.from_url(config.redis_url)
    
    # Find all keys for the old tenant
    keys = await client.keys(f"tenant:{old_tenant}:*")
    
    for key in keys:
        key_str = key.decode("utf-8")
        # Replace the old tenant ID with the new one
        new_key_str = key_str.replace(f"tenant:{old_tenant}:", f"tenant:{new_tenant}:")
        
        # Rename the key
        try:
            await client.rename(key_str, new_key_str)
            print(f"Migrated {key_str} to {new_key_str}")
        except Exception as e:  # noqa: BLE001
            print(f"Error migrating {key_str}: {e}")
            
    # Threads are also stored under a global set? No, threads are tenant specific.
    print(f"Migration from {old_tenant} to {new_tenant} complete.")
    await client.aclose()

if __name__ == "__main__":
    asyncio.run(migrate_tenant_data("local_personal_user", "2b0d4cab-503e-4827-91d6-5806e587b15f"))
