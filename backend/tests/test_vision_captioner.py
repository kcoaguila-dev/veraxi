from unittest.mock import MagicMock, patch

from backend.ingestion.vision import (
    DEFAULT_VISION_PROMPT,
    NoOpVisionCaptioner,
    OpenAIVisionCaptioner,
    get_vision_captioner,
    should_escalate_to_vlm,
)


def test_noop_vision_captioner():
    captioner = NoOpVisionCaptioner()
    result = captioner.caption_image(b"fake_image_bytes")
    assert result == ""


def test_should_escalate_to_vlm_small_dimension():
    # Small dimensions (e.g. 50x50 icon) should not escalate
    assert not should_escalate_to_vlm(width=50, height=50)
    assert not should_escalate_to_vlm(width=200, height=80)


def test_should_escalate_to_vlm_rich_caption():
    # If author provided a detailed caption (>15 words), do not escalate
    rich_caption = (
        "Figure 1.2: A comprehensive architectural flowchart illustrating the end-to-end "
        "lifecycle of document ingestion across distributed microservices and databases."
    )
    assert not should_escalate_to_vlm(
        width=800,
        height=600,
        existing_caption=rich_caption,
        ocr_text="Input Output",
    )


def test_should_escalate_to_vlm_diagram_detection():
    # Large image (>80k px) with minimal OCR text (<15 words) and short caption -> Diagram!
    assert should_escalate_to_vlm(
        width=600,
        height=400,
        existing_caption="Fig 3",
        ocr_text="Step 1 Step 2",
    )


def test_should_escalate_to_vlm_scanned_text_page():
    # Large image with dense OCR text (e.g. 150 words) -> Scanned text page, Docling is enough
    dense_ocr = " ".join([f"word_{i}" for i in range(120)])
    assert not should_escalate_to_vlm(
        width=800,
        height=1000,
        existing_caption="",
        ocr_text=dense_ocr,
    )


def test_openai_vision_captioner_success():
    with patch("openai.OpenAI") as mock_openai_cls:
        mock_client = MagicMock()
        mock_openai_cls.return_value = mock_client

        mock_choice = MagicMock()
        mock_choice.message.content = "A detailed diagram of corporate debt restructuring."
        mock_response = MagicMock()
        mock_response.choices = [mock_choice]
        mock_client.chat.completions.create.return_value = mock_response

        captioner = OpenAIVisionCaptioner(
            base_url="http://localhost:11434/v1",
            api_key="test-key",
            model_name="moondream3",
        )
        caption = captioner.caption_image(b"fake_jpeg_bytes")

        assert caption == "A detailed diagram of corporate debt restructuring."
        mock_client.chat.completions.create.assert_called_once()
        call_kwargs = mock_client.chat.completions.create.call_args[1]
        assert call_kwargs["model"] == "moondream3"
        messages = call_kwargs["messages"]
        assert len(messages) == 1
        user_content = messages[0]["content"]
        assert user_content[0]["text"] == DEFAULT_VISION_PROMPT
        assert user_content[1]["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_openai_vision_captioner_error_handling():
    with patch("openai.OpenAI") as mock_openai_cls:
        mock_client = MagicMock()
        mock_openai_cls.return_value = mock_client
        mock_client.chat.completions.create.side_effect = RuntimeError("Connection refused")

        captioner = OpenAIVisionCaptioner(
            base_url="http://localhost:11434/v1",
            model_name="moondream3",
        )
        caption = captioner.caption_image(b"fake_bytes")
        assert caption == ""


def test_get_vision_captioner_factory():
    class DummyConfig:
        vision_enabled = False
        vision_base_url = ""
        vision_api_key = ""
        vision_model_name = "moondream3"

    cfg = DummyConfig()
    captioner = get_vision_captioner(cfg)
    assert isinstance(captioner, NoOpVisionCaptioner)

    cfg.vision_enabled = True
    cfg.vision_base_url = "http://localhost:11434/v1"
    with patch("openai.OpenAI"):
        captioner = get_vision_captioner(cfg)
        assert isinstance(captioner, OpenAIVisionCaptioner)
