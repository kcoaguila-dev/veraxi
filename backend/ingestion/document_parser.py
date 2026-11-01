"""Shared document-to-markdown conversion with page markers for citations."""

import logging
import re

import sentry_sdk

logger = logging.getLogger(__name__)

_PAGE_MARKER_RE = re.compile(r"<!--\s*page:(\d+)\s*-->")


def extract_pdf_with_pypdf(file_path: str, include_page_markers: bool = True) -> str:
    """Extract text from a PDF using pypdf, optionally prefixing each page with <!-- page:N -->."""
    import pypdf

    reader = pypdf.PdfReader(file_path)
    pages: list[str] = []
    for idx, page in enumerate(reader.pages, start=1):
        page_text = page.extract_text() or ""
        if page_text.strip():
            if include_page_markers:
                pages.append(f"<!-- page:{idx} -->\n{page_text.strip()}")
            else:
                pages.append(page_text.strip())
    return "\n\n".join(pages)


def convert_document_to_markdown(
    source_path_or_url: str,
    parser: str = "pypdf",
    include_page_markers: bool = True,
) -> str:
    """Convert a local file or URL to markdown text using pypdf or lazy-loaded Docling."""
    is_url = source_path_or_url.startswith(("http://", "https://"))
    lower_path = source_path_or_url.lower()

    if not is_url and lower_path.endswith((".txt", ".md")):
        with open(source_path_or_url, "r", encoding="utf-8", errors="replace") as f:
            return f.read()

    if not is_url and parser == "pypdf" and lower_path.endswith(".pdf"):
        try:
            text = extract_pdf_with_pypdf(
                source_path_or_url, include_page_markers=include_page_markers
            )
            if text.strip():
                return text
        except Exception as err:
            logger.warning(
                f"pypdf extraction failed for {source_path_or_url}, falling back to Docling: {err}"
            )

    try:
        from docling.document_converter import DocumentConverter

        converter = DocumentConverter()
        result = converter.convert(source_path_or_url)
        return result.document.export_to_markdown()
    except Exception as err:
        logger.error(f"Document conversion failed for {source_path_or_url}: {err}")
        raise


def extract_attachment_text(
    file_path: str,
    filename: str | None,
    content: bytes,
    mime_type: str,
    parser: str = "pypdf",
) -> str:
    """Extract text from a chat file attachment using direct UTF-8 decode or convert_document_to_markdown."""
    fallback = f"File {filename or 'unknown'} uploaded."
    if mime_type.startswith("text/") or mime_type in (
        "application/json",
        "application/csv",
    ):
        try:
            return content.decode("utf-8")
        except Exception as err:
            logger.warning("Failed to decode text/csv file content: %s", repr(err))
            sentry_sdk.capture_exception(err)
            return fallback

    try:
        return convert_document_to_markdown(
            file_path, parser=parser, include_page_markers=False
        )
    except Exception as err:
        logger.warning(f"Could not convert attachment {filename}: {err}")
        return fallback


def strip_and_resolve_page_number(
    chunk_text: str, last_known_page: int | None = None
) -> tuple[str, int | None]:
    """Extract the latest <!-- page:N --> marker from chunk_text and return (cleaned_text, page_number)."""
    matches = _PAGE_MARKER_RE.findall(chunk_text)
    page_num = int(matches[-1]) if matches else last_known_page
    cleaned = _PAGE_MARKER_RE.sub("", chunk_text).strip()
    return (cleaned or chunk_text.strip()), page_num
