import asyncio
from openai import AsyncOpenAI
import os

async def main():
    client = AsyncOpenAI(api_key="fake")
    try:
        await client.audio.speech.create(model="tts-1", voice="alloy", input="hello")
    except Exception as e:
        print("Exception:", e)

asyncio.run(main())
