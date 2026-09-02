import asyncio
import json

import redis.asyncio as redis


async def main():
    r = redis.from_url('redis://localhost:6379')
    schema = {
        "entities": ["Person", "Organization", "Location", "Concept", "Technology", "Protocol", "Device", "Software"],
        "relations": {
            "Person": {"Organization": ["WORKS_AT", "FOUNDED"]},
            "Concept": {"Concept": ["RELATED_TO", "PART_OF"]},
            "Technology": {"Concept": ["IMPLEMENTS", "USES"]},
            "Device": {"Protocol": ["USES_PROTOCOL"]},
            "Organization": {"Technology": ["DEVELOPS"]}
        }
    }
    # For testing, we use the default tenant ID from api keys if none provided, but let's assume 'default' or check keys
    await r.set("tenant:default:schema", json.dumps(schema))
    # We should also set it for the specific API key tenant if there is one
    print("Schema set in Redis for tenant:default!")

asyncio.run(main())
