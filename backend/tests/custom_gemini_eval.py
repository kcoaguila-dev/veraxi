from deepeval.models.base_model import DeepEvalBaseLLM
from google import genai
from google.genai import types
from backend.config import get_config
import asyncio

class GeminiDeepEvalModel(DeepEvalBaseLLM):
    """
    Custom DeepEval Judge that uses the native google-genai SDK 
    to evaluate metrics using the configured Gemini model.
    """
    def __init__(self):
        self.config = get_config()
        self.client = genai.Client(api_key=self.config.llm_api_key)
        self.model_name = self.config.llm_model_name

    def load_model(self):
        return self.client

    def generate(self, prompt: str) -> str:
        response = self.client.models.generate_content(
            model=self.model_name,
            contents=[prompt],
            config=types.GenerateContentConfig(temperature=0.0)
        )
        return response.text

    async def a_generate(self, prompt: str) -> str:
        # DeepEval uses async for parallel evaluations.
        # google-genai supports async via client.aio.models.generate_content
        response = await self.client.aio.models.generate_content(
            model=self.model_name,
            contents=[prompt],
            config=types.GenerateContentConfig(temperature=0.0)
        )
        return response.text

    def get_model_name(self):
        return self.model_name
