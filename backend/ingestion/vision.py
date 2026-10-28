"""
backend/ingestion/vision.py

Model-agnostic vision captioning adapter and adaptive layout routing for Veraxi.
Supports local (Ollama, vLLM, llama.cpp, LM Studio, Moondream 3.1) and cloud (OpenAI, Gemini)
vision providers via the standard OpenAI-compatible vision protocol.
"""

from __future__ import annotations

import base64
import logging
from typing import Any, Protocol

logger = logging.getLogger(__name__)

DEFAULT_VISION_PROMPT = (
    "Provide a concise, detailed 2-3 sentence description of this image, flowchart, or diagram "
    "for semantic search and knowledge graph indexing. "
    "Explicitly name all visible entities, text labels, values, and causal relationships."
)


class VisionCaptioner(Protocol):
    """Protocol for model-agnostic visual captioning engines."""

    def caption_image(self, image_bytes: bytes, mime_type: str = "image/jpeg") -> str:
        """Generates a descriptive semantic caption for the given image bytes."""
        ...


class NoOpVisionCaptioner:
    """Default no-op captioner used when vision is disabled or on free tiers."""

    def caption_image(self, image_bytes: bytes, mime_type: str = "image/jpeg") -> str:
        return ""


class OpenAIVisionCaptioner:
    """Universal model-agnostic captioner using standard OpenAI-compatible Vision API.

    Works out-of-the-box with:
      - Local runners: Ollama (moondream3, qwen2.5-vl), vLLM, llama-server, LocalAI
      - Cloud providers: OpenAI (gpt-4o-mini), Google (gemini via OpenAI compat), OpenRouter, Groq
    """

    def __init__(
        self,
        base_url: str,
        api_key: str = "",
        model_name: str = "moondream3",
        prompt: str = DEFAULT_VISION_PROMPT,
        timeout: float = 30.0,
    ):
        from openai import OpenAI

        # Strip trailing slash if present, provide fallback dummy key for local endpoints
        clean_base_url = base_url.rstrip("/") if base_url else ""
        self.client = OpenAI(
            base_url=clean_base_url or None,
            api_key=api_key or "local-no-key",
            timeout=timeout,
        )
        self.model_name = model_name
        self.prompt = prompt

    def caption_image(self, image_bytes: bytes, mime_type: str = "image/jpeg") -> str:
        if not image_bytes:
            return ""

        b64_img = base64.b64encode(image_bytes).decode("utf-8")
        try:
            response = self.client.chat.completions.create(
                model=self.model_name,
                messages=[
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": self.prompt},
                            {
                                "type": "image_url",
                                "image_url": {
                                    "url": f"data:{mime_type};base64,{b64_img}"
                                },
                            },
                        ],
                    }
                ],
                max_tokens=200,
            )
            choice = response.choices[0]
            content = choice.message.content or ""
            return content.strip()
        except Exception as e:
            logger.warning(
                f"Vision captioning failed via {self.model_name} at {self.client.base_url}: {e}"
            )
            return ""


def should_escalate_to_vlm(
    width: int,
    height: int,
    existing_caption: str = "",
    ocr_text: str = "",
    min_dimension: int = 120,
    rich_caption_word_threshold: int = 15,
    min_area_for_diagram: int = 80_000,
    max_ocr_words_for_diagram: int = 15,
) -> bool:
    """Adaptive 95/5 routing heuristic to decide if an image needs a Vision AI.

    Signals:
      1. Dimension Filter: Skip decorative icons, bullets, and divider lines.
      2. Caption Completeness: If author provided a detailed caption (>= 15 words), Docling text is enough.
      3. OCR Density vs Area:
         - Large visual element (> 80k pixels) with sparse OCR text (< 15 words) -> Diagram/Chart/Photo!
           Needs VLM to extract the trapped semantic visual meaning.
         - High OCR word count relative to size -> Scanned document page (Docling OCR is sufficient).
    """
    # Signal 1: Skip tiny icons, dividers, bullets
    if width < min_dimension or height < min_dimension:
        return False

    # Signal 2: If author already supplied a detailed caption, skip expensive VLM
    caption_words = len(existing_caption.strip().split())
    if caption_words >= rich_caption_word_threshold:
        return False

    # Signal 3: OCR Density check
    area = width * height
    ocr_words = len(ocr_text.strip().split())

    # Large image with few words indicates a photo, schematic, or flowchart
    if area >= min_area_for_diagram and ocr_words <= max_ocr_words_for_diagram:
        return True

    # If image has completely zero caption and zero OCR text, escalate
    if not existing_caption.strip() and not ocr_text.strip() and area >= min_area_for_diagram:
        return True

    return False


def get_vision_captioner(config: Any) -> VisionCaptioner:
    """Factory creating the appropriate VisionCaptioner based on configuration."""
    if not getattr(config, "vision_enabled", False):
        return NoOpVisionCaptioner()

    base_url = getattr(config, "vision_base_url", "")
    api_key = getattr(config, "vision_api_key", "")
    model_name = getattr(config, "vision_model_name", "moondream3")
    prompt = getattr(config, "vision_prompt", DEFAULT_VISION_PROMPT)

    if not base_url and not api_key:
        logger.info("Vision enabled but no base_url or api_key configured. Using NoOpVisionCaptioner.")
        return NoOpVisionCaptioner()

    return OpenAIVisionCaptioner(
        base_url=base_url,
        api_key=api_key,
        model_name=model_name,
        prompt=prompt,
    )
