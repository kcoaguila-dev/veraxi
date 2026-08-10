import os
import httpx
import logging

logger = logging.getLogger(__name__)

async def moderate_text(text: str, api_key: str | None = None) -> bool:
    """
    Calls the free OpenAI Moderation API to check if the text violates safety policies.
    Returns True if the text is flagged (violates policy), False otherwise.
    If no API key is available or the request fails, it fails open (returns False)
    so as not to block legitimate requests during outages.
    """
    key = api_key or os.environ.get("OPENAI_API_KEY")
    if not key:
        logger.debug("No OpenAI API key available for moderation. Skipping.")
        return False
        
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                "https://api.openai.com/v1/moderations",
                headers={
                    "Authorization": f"Bearer {key}",
                    "Content-Type": "application/json"
                },
                json={"input": text},
                timeout=5.0
            )
            response.raise_for_status()
            data = response.json()
            
            # The API returns a list of results (one per input string)
            results = data.get("results", [])
            if results:
                is_flagged = results[0].get("flagged", False)
                if is_flagged:
                    logger.warning(f"Text flagged by moderation API. Categories: {results[0].get('categories')}")
                return is_flagged
                
    except Exception as e:
        logger.error(f"Error calling moderation API: {e}")
        # Fail open
        return False
        
    return False
