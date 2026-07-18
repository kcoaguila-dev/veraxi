from deepeval.models.base_model import DeepEvalBaseLLM
from openai import OpenAI, AsyncOpenAI
from backend.config import get_config

class OpenAIDeepEvalModel(DeepEvalBaseLLM):
    """
    Custom DeepEval Judge that uses the openai SDK 
    to evaluate metrics using the configured model.
    """
    def __init__(self):
        self.config = get_config()
        client_args = {}
        if self.config.llm_api_key:
            client_args["api_key"] = self.config.llm_api_key
        if self.config.llm_base_url:
            client_args["base_url"] = self.config.llm_base_url
            
        self.client = OpenAI(**client_args)
        self.async_client = AsyncOpenAI(**client_args)
        self.model_name = self.config.llm_model_name

    def load_model(self):
        return self.client

    def generate(self, prompt: str) -> str:
        response = self.client.chat.completions.create(
            model=self.model_name,
            messages=[{"role": "user", "content": prompt}],
            temperature=0.0
        )
        return response.choices[0].message.content

    async def a_generate(self, prompt: str) -> str:
        # DeepEval uses async for parallel evaluations.
        response = await self.async_client.chat.completions.create(
            model=self.model_name,
            messages=[{"role": "user", "content": prompt}],
            temperature=0.0
        )
        return response.choices[0].message.content

    def get_model_name(self):
        return self.model_name
