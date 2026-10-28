import argparse
import logging
import os
import sys

# Add backend directory to Python path if run from scripts folder
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.config import get_config
from backend.ingestion.__main__ import run_ingestion
from backend.ingestion.vision import (
    NoOpVisionCaptioner,
    VisionCaptioner,
    get_vision_captioner,
)

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)


def _extract_pdf_pypdf(file_path: str) -> str:
    """Fast PDF text extraction via pypdf."""
    try:
        import pypdf

        reader = pypdf.PdfReader(file_path)
        pages_text = []
        for page in reader.pages:
            t = page.extract_text()
            if t:
                pages_text.append(t)
        return "\n\n".join(pages_text)
    except Exception as e:
        logger.warning(f"pypdf extraction failed for {file_path}: {e}")
        return ""


def extract_text(
    file_path: str,
    parser: str = "docling",
    fast: bool = False,
    vision_captioner: VisionCaptioner | None = None,
) -> str:
    """Extracts text from PDF, MD, or TXT files, with optional adaptive vision."""
    ext = os.path.splitext(file_path)[1].lower()

    # Detect if file is a PDF (by extension or magic bytes %PDF-)
    is_pdf = ext == ".pdf"
    if not is_pdf and os.path.exists(file_path):
        try:
            with open(file_path, "rb") as f:
                header = f.read(5)
                if header.startswith(b"%PDF-"):
                    is_pdf = True
        except OSError as err:
            logger.debug("Could not inspect file header for %s: %s", file_path, err)

    if is_pdf:
        # If explicitly set to pypdf parser, extract text via fast pypdf stream
        if parser == "pypdf":
            logger.info("Extracting PDF text via fast pypdf parser...")
            text = _extract_pdf_pypdf(file_path)
            if text.strip():
                return text
            logger.info("Fast pypdf returned empty text, falling back to Docling...")

        has_active_vision = vision_captioner is not None and not isinstance(
            vision_captioner, NoOpVisionCaptioner
        )

        try:
            from io import BytesIO

            from docling.document_converter import DocumentConverter

            from backend.ingestion.vision import should_escalate_to_vlm

            logger.info(
                "Parsing PDF with Docling AI models & TableFormer (this may take a moment)..."
            )
            converter = DocumentConverter()
            result = converter.convert(file_path)
            doc = result.document
            markdown = doc.export_to_markdown()

            if has_active_vision:
                visual_summaries = []
                pictures = getattr(doc, "pictures", [])
                logger.info(
                    f"Found {len(pictures)} visual elements. Running adaptive vision escalation..."
                )
                for idx, pic in enumerate(pictures):
                    try:
                        img = pic.get_image(doc)
                        if not img:
                            continue
                        w, h = img.size
                        caption = pic.caption_text(doc) or ""
                        if should_escalate_to_vlm(
                            width=w, height=h, existing_caption=caption
                        ):
                            buf = BytesIO()
                            img.save(buf, format="JPEG")
                            img_bytes = buf.getvalue()
                            assert vision_captioner is not None
                            vlm_caption = vision_captioner.caption_image(img_bytes)
                            if vlm_caption:
                                visual_summaries.append(
                                    f"### Visual Figure {idx + 1}\n{vlm_caption}"
                                )
                    except Exception as err:
                        logger.debug(
                            "Vision extraction skipped for picture %d: %s", idx, err
                        )

                if visual_summaries:
                    logger.info(
                        f"Enriched document with {len(visual_summaries)} visual descriptions via Vision AI."
                    )
                    markdown += (
                        "\n\n## Visual Elements & Diagram Analysis\n\n"
                        + "\n\n".join(visual_summaries)
                    )

            return markdown
        except Exception as e:
            logger.warning(f"Docling extraction failed for {file_path}: {e}")
            return _extract_pdf_pypdf(file_path)

    # For text / markdown or UTF-8 files
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return f.read()
    except UnicodeDecodeError as err:
        logger.debug("UTF-8 decoding failed for %s: %s", file_path, err)
    except OSError as err:
        logger.debug("Failed opening file %s: %s", file_path, err)

    logger.warning(
        f"File {file_path} is neither a valid PDF nor UTF-8 text."
    )
    return ""


def main():
    parser = argparse.ArgumentParser(description="Veraxi Batch Ingestion CLI")
    parser.add_argument(
        "--dir", type=str, required=True, help="Directory containing files to ingest"
    )
    parser.add_argument(
        "--tenant",
        type=str,
        help="Tenant ID to ingest as (required if Auth is enabled and not self-hosting)",
    )
    parser.add_argument(
        "--parser",
        type=str,
        choices=["docling", "pypdf"],
        default="docling",
        help="PDF parser engine: 'docling' (default, layout & TableFormer AI) or 'pypdf' (fast stream)",
    )
    parser.add_argument(
        "--fast",
        action="store_true",
        help="Use fast entity extraction (CPU/spaCy) instead of Deep Extraction (LLM)",
    )
    parser.add_argument(
        "--vision",
        action="store_true",
        help="Enable adaptive vision captioning for complex images/diagrams using configured Vision model",
    )
    parser.add_argument(
        "--vision-model",
        type=str,
        default=None,
        help="Override vision model name (e.g. moondream3, qwen2.5-vl:3b, gpt-4o-mini)",
    )
    parser.add_argument(
        "--vision-base-url",
        type=str,
        default=None,
        help="Override vision base URL (e.g. http://localhost:11434/v1)",
    )
    parser.add_argument(
        "--chunk-size", type=int, default=300, help="Chunk size for embedding"
    )
    parser.add_argument(
        "--chunk-overlap", type=int, default=50, help="Chunk overlap for embedding"
    )

    args = parser.parse_args()
    config = get_config()

    # Admin Security Verification
    if config.auth_enabled:
        admin_ids = config.admin_tenant_ids
        if not admin_ids:
            logger.error(
                "Auth is enabled but no ADMIN_TENANT_IDS are set in the environment."
            )
            sys.exit(1)

        if not args.tenant:
            logger.info(
                f"No tenant ID provided. Auto-selecting Admin Tenant ID: {admin_ids[0]}"
            )
            tenant_id = admin_ids[0]
        else:
            if args.tenant not in admin_ids:
                logger.error(
                    f"Security Alert: Tenant {args.tenant} is NOT in the ADMIN_TENANT_IDS allowlist."
                )
                logger.error(
                    "Batch ingestion is restricted to administrators only to prevent resource exhaustion."
                )
                sys.exit(1)
            tenant_id = args.tenant
    else:
        # Self-Hosted Mode
        tenant_id = args.tenant if args.tenant else "default"
        logger.info(f"Self-hosted mode detected. Using tenant: {tenant_id}")

    if not os.path.isdir(args.dir):
        logger.error(f"Directory not found: {args.dir}")
        sys.exit(1)

    # Generic schema required by run_ingestion
    schema = {
        "entities": [
            "Concept",
            "Person",
            "Organization",
            "Event",
            "Document",
            "FinancialMetric",
        ],
        "relations": {
            "Person": {"Organization": ["WORKS_FOR", "FOUNDED", "INVESTED_IN"]},
            "Organization": {"FinancialMetric": ["REPORTED", "MANIPULATED"]},
            "Concept": {"Event": ["CAUSED", "RELATED_TO"]},
        },
    }

    # Grab all files in directory
    files = [
        os.path.join(args.dir, f)
        for f in os.listdir(args.dir)
        if os.path.isfile(os.path.join(args.dir, f))
    ]
    if not files:
        logger.info(f"No files found in {args.dir}")
        return

    # Vision captioner setup
    if args.vision:
        config.vision_enabled = True
    if args.vision_model:
        config.vision_model_name = args.vision_model
    if args.vision_base_url:
        config.vision_base_url = args.vision_base_url

    captioner = get_vision_captioner(config)
    has_active_vision = not isinstance(captioner, NoOpVisionCaptioner)

    logger.info(
        f"Found {len(files)} files for batch ingestion. Parser: {args.parser.upper()} | Entity Extraction: {'Fast (CPU spaCy)' if args.fast else 'Deep (LLM)'} | Vision: {'Active (' + config.vision_model_name + ')' if has_active_vision else 'Disabled'}"
    )

    for file_path in files:
        filename = os.path.basename(file_path)
        logger.info("==================================================")
        logger.info(f"Processing: {filename}")

        text = extract_text(
            file_path,
            parser=args.parser,
            fast=args.fast,
            vision_captioner=captioner,
        )
        if not text.strip():
            logger.warning(f"No text extracted from {filename}. Skipping.")
            continue

        logger.info(
            f"Extracted {len(text)} characters. Starting Veraxi ingestion pipeline..."
        )

        try:
            result = run_ingestion(
                config=config,
                text=text,
                schema=schema,
                tenant_id=tenant_id,
                fast_extraction=args.fast,
                language="en",
                chunk_size=args.chunk_size,
                chunk_overlap=args.chunk_overlap,
            )
            logger.info(f"Successfully ingested {filename}: {result}")
        except Exception:
            logger.exception("Ingestion failed for %s", filename)


if __name__ == "__main__":
    main()
