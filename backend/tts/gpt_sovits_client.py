import logging

import httpx
from backend.config import get_config

logger = logging.getLogger(__name__)

class GPTSoVITSClient:
    def __init__(self, base_url: str | None = None):
        if not base_url:
            config = get_config()
            base_url = config.gpt_sovits_base_url
        self.base_url = base_url.rstrip("/")
        self.client = httpx.AsyncClient(timeout=300.0)

    async def synthesize(self, text: str, ref_audio_path: str, prompt_text: str, prompt_lang: str = "en", text_lang: str = "en"):
        """
        Synthesizes text into speech using GPT-SoVITS API.
        """
        params = {
            "text": text,
            "text_lang": text_lang,
            "ref_audio_path": ref_audio_path,
            "prompt_text": prompt_text,
            "prompt_lang": prompt_lang
        }

        endpoint = f"{self.base_url}/tts"
        try:
            response = await self.client.get(endpoint, params=params)

            if response.status_code == 404:
                endpoint = f"{self.base_url}/"
                response = await self.client.get(endpoint, params=params)

            response.raise_for_status()
            return response.content
        except Exception as e:
            logger.error(f"Error calling GPT-SoVITS API: {e}")
            raise

    async def check_connection(self):
        """Pings the base URL to verify connection."""
        try:
            response = await self.client.get(f"{self.base_url}/tts")
            if response.status_code >= 500:
                raise Exception(f"Server error: {response.status_code}")  # noqa: TRY002
            if response.status_code == 404 and "ngrok" in response.text.lower():
                raise Exception("Ngrok tunnel not found")  # noqa: TRY002
            return True
        except Exception as e:  # noqa: BLE001
            logger.error(f"GPT-SoVITS connection failed: {e}")
            raise ConnectionError(f"Could not connect to GPT-SoVITS at {self.base_url}")

    async def close(self):
        await self.client.aclose()
