"""Shared OpenAI-compatible DeepEval LLM wrapper with structured JSON support.

Supports local vLLM / SGLang / Ollama endpoints via ``LLM_BASE_URL`` or dedicated
``JUDGE_LLM_BASE_URL`` / ``JUDGE_LLM_API_KEY`` / ``JUDGE_LLM_MODEL_NAME`` overrides,
XGrammar ``json_schema`` constrained decoding with ``json_object`` fallback, and
stripping of ``<think>...</think>`` reasoning blocks and markdown code fences.
"""

from __future__ import annotations

import logging
import os
import re
from typing import Any

from deepeval.models.base_model import DeepEvalBaseLLM
from openai import AsyncOpenAI, OpenAI
from pydantic import BaseModel

from backend.config import get_config

logger = logging.getLogger(__name__)

_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)
_FENCE_RE = re.compile(r"^```(?:json)?\s*\n?(.*?)\n?```$", re.DOTALL | re.IGNORECASE)


def strip_think_and_fences(text: str) -> str:
    """Remove ``<think>...</think>`` blocks and outer markdown code fences."""
    cleaned = _THINK_RE.sub("", text or "").strip()
    fence_match = _FENCE_RE.match(cleaned)
    if fence_match:
        cleaned = fence_match.group(1).strip()
    return cleaned


def _resolve_judge_client_config() -> tuple[dict[str, Any], str]:
    """Resolve OpenAI client kwargs and model name for the judge LLM."""
    config = get_config()
    judge_base_url = os.environ.get("JUDGE_LLM_BASE_URL", "").strip()
    judge_api_key = os.environ.get("JUDGE_LLM_API_KEY", "").strip()
    judge_model = os.environ.get("JUDGE_LLM_MODEL_NAME", "").strip()

    model_name = judge_model or config.llm_model_name
    client_args = config.get_llm_client_args(model_name=model_name)

    if judge_base_url:
        client_args["base_url"] = judge_base_url
    if judge_api_key:
        client_args["api_key"] = judge_api_key
    if client_args.get("base_url") and not client_args.get("api_key"):
        client_args["api_key"] = "local"

    return client_args, model_name


def _schema_response_format(schema: type[BaseModel]) -> dict[str, Any]:
    return {
        "type": "json_schema",
        "json_schema": {
            "name": schema.__name__,
            "schema": schema.model_json_schema(),
        },
    }


def _parse_schema_output(raw_text: str, schema: type[BaseModel] | None) -> Any:
    cleaned = strip_think_and_fences(raw_text)
    if schema is None:
        return cleaned
    return schema.model_validate_json(cleaned)


class OpenAIDeepEvalModel(DeepEvalBaseLLM):
    """Custom DeepEval Judge using OpenAI-compatible sync and async clients."""

    def __init__(self, model_name: str | None = None, **kwargs: Any) -> None:
        client_args, resolved_model = _resolve_judge_client_config()
        self.model_name = model_name or resolved_model
        self.client = OpenAI(**client_args)
        self.async_client = AsyncOpenAI(**client_args)
        super().__init__(**kwargs)

    def load_model(self) -> OpenAI:
        return self.client

    def get_model_name(self) -> str:
        return self.model_name

    def generate(
        self, prompt: str, schema: type[BaseModel] | None = None
    ) -> BaseModel | str:
        messages = [{"role": "user", "content": prompt}]
        if schema is None:
            response = self.client.chat.completions.create(
                model=self.model_name,
                messages=messages,
                temperature=0.0,
            )
            return _parse_schema_output(response.choices[0].message.content or "", None)

        try:
            response = self.client.chat.completions.create(
                model=self.model_name,
                messages=messages,
                response_format=_schema_response_format(schema),
                temperature=0.0,
            )
        except Exception as exc:
            logger.debug("json_schema rejected (%s); falling back to json_object", exc)
            response = self.client.chat.completions.create(
                model=self.model_name,
                messages=messages,
                response_format={"type": "json_object"},
                temperature=0.0,
            )
        return _parse_schema_output(response.choices[0].message.content or "", schema)

    async def a_generate(
        self, prompt: str, schema: type[BaseModel] | None = None
    ) -> BaseModel | str:
        messages = [{"role": "user", "content": prompt}]
        if schema is None:
            response = await self.async_client.chat.completions.create(
                model=self.model_name,
                messages=messages,
                temperature=0.0,
            )
            return _parse_schema_output(response.choices[0].message.content or "", None)

        try:
            response = await self.async_client.chat.completions.create(
                model=self.model_name,
                messages=messages,
                response_format=_schema_response_format(schema),
                temperature=0.0,
            )
        except Exception as exc:
            logger.debug("async json_schema rejected (%s); falling back to json_object", exc)
            response = await self.async_client.chat.completions.create(
                model=self.model_name,
                messages=messages,
                response_format={"type": "json_object"},
                temperature=0.0,
            )
        return _parse_schema_output(response.choices[0].message.content or "", schema)
