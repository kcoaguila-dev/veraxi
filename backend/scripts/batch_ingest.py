import argparse
import logging
import os
import sys

# Add backend directory to Python path if run from scripts folder
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.config import get_config
from backend.ingestion.__main__ import run_ingestion

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

def extract_text(file_path: str) -> str:
    """Extracts text from PDF, MD, or TXT files using IBM Docling."""
    ext = os.path.splitext(file_path)[1].lower()
    
    if ext == ".pdf":
        try:
            from docling.document_converter import DocumentConverter
            logger.info("Parsing PDF with Docling AI models (this may take a moment)...")
            converter = DocumentConverter()
            result = converter.convert(file_path)
            # Docling natively preserves layout and tables as Markdown
            return result.document.export_to_markdown()
        except Exception as e:
            logger.error(f"Failed to read PDF {file_path} with Docling: {e}")
            return ""
            
    elif ext in [".txt", ".md"]:
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                return f.read()
        except Exception as e:
            logger.error(f"Failed to read text file {file_path}: {e}")
            return ""
            
    # For binary files without extensions (e.g. some PDFs from Anna's Archive)
    try:
        from docling.document_converter import DocumentConverter
        logger.info("Parsing binary file with Docling AI models...")
        converter = DocumentConverter()
        result = converter.convert(file_path)
        return result.document.export_to_markdown()
    except Exception:
        # If it's not a valid PDF, try reading as plain text
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                return f.read()
        except Exception:
            logger.warning(f"File {file_path} is neither a valid document nor UTF-8 text.")
            return ""

def main():
    parser = argparse.ArgumentParser(description="Veraxi Batch Ingestion CLI")
    parser.add_argument("--dir", type=str, required=True, help="Directory containing files to ingest")
    parser.add_argument("--tenant", type=str, help="Tenant ID to ingest as (required if Auth is enabled and not self-hosting)")
    parser.add_argument("--fast", action="store_true", help="Use fast extraction (CPU/spaCy) instead of Deep Extraction (LLM)")
    parser.add_argument("--chunk-size", type=int, default=300, help="Chunk size for embedding")
    parser.add_argument("--chunk-overlap", type=int, default=50, help="Chunk overlap for embedding")
    
    args = parser.parse_args()
    config = get_config()

    # Admin Security Verification
    if config.auth_enabled:
        admin_ids = config.admin_tenant_ids
        if not admin_ids:
            logger.error("Auth is enabled but no ADMIN_TENANT_IDS are set in the environment.")
            sys.exit(1)
            
        if not args.tenant:
            logger.info(f"No tenant ID provided. Auto-selecting Admin Tenant ID: {admin_ids[0]}")
            tenant_id = admin_ids[0]
        else:
            if args.tenant not in admin_ids:
                logger.error(f"Security Alert: Tenant {args.tenant} is NOT in the ADMIN_TENANT_IDS allowlist.")
                logger.error("Batch ingestion is restricted to administrators only to prevent resource exhaustion.")
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
        "entities": ["Concept", "Person", "Organization", "Event", "Document", "FinancialMetric"],
        "relations": {
            "Person": {"Organization": ["WORKS_FOR", "FOUNDED", "INVESTED_IN"]},
            "Organization": {"FinancialMetric": ["REPORTED", "MANIPULATED"]},
            "Concept": {"Event": ["CAUSED", "RELATED_TO"]}
        },
    }

    # Grab all files in directory
    files = [os.path.join(args.dir, f) for f in os.listdir(args.dir) if os.path.isfile(os.path.join(args.dir, f))]
    if not files:
        logger.info(f"No files found in {args.dir}")
        return

    logger.info(f"Found {len(files)} files for batch ingestion. Extraction Mode: {'Fast (CPU)' if args.fast else 'Deep (LLM)'}")

    for file_path in files:
        filename = os.path.basename(file_path)
        logger.info(f"==================================================")
        logger.info(f"Processing: {filename}")
        
        text = extract_text(file_path)
        if not text.strip():
            logger.warning(f"No text extracted from {filename}. Skipping.")
            continue
            
        logger.info(f"Extracted {len(text)} characters. Starting Veraxi ingestion pipeline...")
        
        try:
            result = run_ingestion(
                config=config,
                text=text,
                schema=schema,
                tenant_id=tenant_id,
                fast_extraction=args.fast,
                language="en",
                chunk_size=args.chunk_size,
                chunk_overlap=args.chunk_overlap
            )
            logger.info(f"Successfully ingested {filename}: {result}")
        except Exception as e:
            logger.error(f"Ingestion failed for {filename}: {e}")

if __name__ == "__main__":
    main()
