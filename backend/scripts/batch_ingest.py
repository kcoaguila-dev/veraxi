import argparse
import hashlib
import logging
import os
import sys

# Add backend directory to Python path if run from scripts folder
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.config import get_config
from backend.ingestion.__main__ import run_ingestion
from backend.storage.qdrant_client import QdrantStorageClient
from backend.ingestion.vision import (
    NoOpVisionCaptioner,
    VisionCaptioner,
    get_vision_captioner,
)

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)


def compute_sha256(file_path: str) -> str:
    """Compute SHA-256 hash of a file efficiently in 64KB blocks."""
    hasher = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def _extract_pdf_pypdf(file_path: str) -> str:
    """Fast PDF text extraction via pypdf with page markers."""
    try:
        from backend.ingestion.document_parser import extract_pdf_with_pypdf

        return extract_pdf_with_pypdf(file_path, include_page_markers=True)
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

        temp_symlink = None
        target_path = file_path
        if not file_path.lower().endswith(".pdf"):
            import tempfile

            with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp_f:
                tmp_name = tmp_f.name
            if os.path.exists(tmp_name):
                os.remove(tmp_name)
            os.symlink(os.path.abspath(file_path), tmp_name)
            temp_symlink = tmp_name
            target_path = temp_symlink

        try:
            from io import BytesIO

            from docling.datamodel.pipeline_options import PdfPipelineOptions
            from docling.document_converter import DocumentConverter, PdfFormatOption

            from backend.ingestion.vision import should_escalate_to_vlm

            logger.info(
                "Parsing PDF with Docling AI models & TableFormer (high-fidelity layout & financial tables)..."
            )
            pipeline_opts = PdfPipelineOptions()
            pipeline_opts.do_ocr = False
            pipeline_opts.do_table_structure = True
            converter = DocumentConverter(
                format_options={"pdf": PdfFormatOption(pipeline_options=pipeline_opts)}
            )
            result = converter.convert(target_path)
            doc = result.document

            # Preserve exact page markers, section breadcrumbs, table flags, and bboxes
            page_items: list[str] = []
            header_stack: list[tuple[int, str]] = []
            current_page_no = None

            for item, level in doc.iterate_items():
                item_type = type(item).__name__
                prov = getattr(item, "prov", None)
                pno = prov[0].page_no if prov else current_page_no
                if pno is not None:
                    current_page_no = pno

                bbox_str = None
                if prov and hasattr(prov[0], "bbox"):
                    b = prov[0].bbox
                    bbox_str = f"{b.l:.1f},{b.t:.1f},{b.r:.1f},{b.b:.1f}"

                if item_type == "SectionHeaderItem" and hasattr(item, "text"):
                    title = item.text.strip()
                    lvl = level or 1
                    while header_stack and header_stack[-1][0] >= lvl:
                        header_stack.pop()
                    if title:
                        header_stack.append((lvl, title))

                breadcrumb = " > ".join(t for _, t in header_stack)
                is_table = item_type == "TableItem"

                marker_parts = [f"page:{current_page_no}"]
                if breadcrumb:
                    marker_parts.append(f"breadcrumb:{breadcrumb}")
                if bbox_str:
                    marker_parts.append(f"bbox:{bbox_str}")
                if is_table:
                    marker_parts.append("table:true")

                marker = "<!-- " + " | ".join(marker_parts) + " -->"

                text = ""
                if hasattr(item, "export_to_markdown"):
                    try:
                        text = item.export_to_markdown(doc=doc)
                    except TypeError:
                        text = item.export_to_markdown()
                elif hasattr(item, "text"):
                    text = item.text

                if text.strip():
                    page_items.append(f"\n\n{marker}\n{text.strip()}")

            markdown = "\n".join(page_items) if page_items else doc.export_to_markdown()

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
        finally:
            if temp_symlink and os.path.exists(temp_symlink):
                try:
                    os.remove(temp_symlink)
                except OSError:
                    pass

    # For text / markdown or UTF-8 files
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return f.read()
    except UnicodeDecodeError as err:
        logger.debug("UTF-8 decoding failed for %s: %s", file_path, err)
    except OSError as err:
        logger.debug("Failed opening file %s: %s", file_path, err)

    logger.warning(f"File {file_path} is neither a valid PDF nor UTF-8 text.")
    return ""


def _purge_replaced_document_from_neo4j(
    config, qdrant, tenant_id: str, filename: str
) -> None:
    """Purges replaced document chunk references from Neo4j, paginating all point IDs."""
    try:
        from qdrant_client.http import models

        from backend.storage.neo4j_client import Neo4jStorageClient

        scroll_filter = models.Filter(
            must=[
                models.FieldCondition(
                    key="tenant_id",
                    match=models.MatchValue(value=tenant_id),
                ),
                models.FieldCondition(
                    key="document_id",
                    match=models.MatchValue(value=filename),
                ),
            ]
        )

        purged_pids: list[str] = []
        offset = None
        while True:
            points_page, offset = qdrant.client.scroll(
                collection_name=config.qdrant_collection_name,
                scroll_filter=scroll_filter,
                limit=1000,
                offset=offset,
                with_payload=False,
                with_vectors=False,
            )
            purged_pids.extend(str(pt.id) for pt in points_page)
            if offset is None or not points_page:
                break

        if purged_pids:
            neo4j = Neo4jStorageClient.from_config(config)
            cleanse_query = """
            MATCH (n)
            WHERE n.tenant_id = $tenant_id AND any(pid IN $purged_pids WHERE pid IN coalesce(n.qdrant_point_ids, []))
            SET n.qdrant_point_ids = [pid IN n.qdrant_point_ids WHERE NOT pid IN $purged_pids]
            WITH n
            WHERE size(n.qdrant_point_ids) = 0
            DETACH DELETE n
            """
            batch_size = 500
            for i in range(0, len(purged_pids), batch_size):
                batch_pids = purged_pids[i : i + batch_size]
                neo4j.execute_write(
                    cleanse_query,
                    {"purged_pids": batch_pids, "tenant_id": tenant_id},
                )
            neo4j.close()
    except Exception as purge_exc:
        logger.warning(
            f"Could not purge Neo4j chunks for replaced document '{filename}': {purge_exc}"
        )


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
        "--chunk-size", type=int, default=800, help="Chunk size for embedding"
    )
    parser.add_argument(
        "--chunk-overlap", type=int, default=150, help="Chunk overlap for embedding"
    )
    parser.add_argument(
        "--replace",
        action="store_true",
        help="Purge any previously ingested chunks for each document_id before fresh ingestion",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force re-ingestion even if identical file SHA-256 hash is already present in Qdrant",
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

    # Initialize storage client for idempotency & replacement checks
    qdrant = QdrantStorageClient.from_config(config)
    qdrant.create_collection(config.qdrant_collection_name)

    logger.info(
        f"Found {len(files)} files for batch ingestion. Parser: {args.parser.upper()} | Entity Extraction: {'Fast (CPU spaCy)' if args.fast else 'Deep (LLM)'} | Vision: {'Active (' + config.vision_model_name + ')' if has_active_vision else 'Disabled'}"
    )

    for file_path in files:
        filename = os.path.basename(file_path)
        file_hash = compute_sha256(file_path)

        logger.info("==================================================")
        logger.info(f"Processing: {filename} (SHA256: {file_hash[:12]}...)")

        # 1. Idempotency Check: Skip identical file if already indexed
        if (
            not args.force
            and not args.replace
            and qdrant.has_file_hash(
                config.qdrant_collection_name, file_hash, tenant_id=tenant_id
            )
        ):
            logger.info(
                f"⏭️  [IDEMPOTENT SKIP] File '{filename}' (hash: {file_hash[:12]}...) is already fully ingested in Qdrant. "
                "Skipping PDF parsing to save GPU/CPU cycles. Pass --force or --replace to reprocess."
            )
            continue

        # 2. Document Replacement Check: Purge existing edition/document chunks if --replace requested
        if args.replace:
            _purge_replaced_document_from_neo4j(config, qdrant, tenant_id, filename)

            deleted_count = qdrant.delete_by_document(
                config.qdrant_collection_name,
                document_id=filename,
                tenant_id=tenant_id,
            )
            if deleted_count > 0:
                logger.info(
                    f"🔄 [REPLACE] Purged {deleted_count} prior chunks for document '{filename}' before fresh re-ingestion."
                )

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
                source=filename,
                document_id=filename,
                source_type="book",
                file_hash=file_hash,
            )
            logger.info(f"Successfully ingested {filename}: {result}")
        except (ValueError, RuntimeError) as e:
            err_lower = str(e).lower()
            if "dimension" in err_lower or "refusing to delete" in err_lower:
                logger.error(
                    "Fatal schema/dimension incompatibility detected: %s. Aborting batch ingestion to prevent wasted compute.",
                    e,
                )
                raise
            logger.exception("Ingestion failed for %s", filename)
        except Exception:
            logger.exception("Ingestion failed for %s", filename)


if __name__ == "__main__":
    main()
