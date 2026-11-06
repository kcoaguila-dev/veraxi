"""Shared document-to-markdown conversion with page markers for citations."""

import logging
import re

import sentry_sdk

logger = logging.getLogger(__name__)

_PAGE_MARKER_RE = re.compile(r"<!--\s*page:(\d+)(.*?)\s*-->")


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
        from docling.datamodel.pipeline_options import PdfPipelineOptions
        from docling.document_converter import DocumentConverter, PdfFormatOption

        opts = PdfPipelineOptions()
        opts.do_ocr = False
        opts.do_table_structure = True
        converter = DocumentConverter(
            format_options={"pdf": PdfFormatOption(pipeline_options=opts)}
        )
        result = converter.convert(source_path_or_url)
        doc = result.document
        if not include_page_markers:
            return doc.export_to_markdown()

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

        return "\n".join(page_items) if page_items else doc.export_to_markdown()
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


def strip_and_resolve_citation_metadata(
    chunk_text: str,
    last_known_page: int | None = None,
    last_known_breadcrumb: str | None = None,
) -> tuple[str, int | None, str | None, list[float] | None, bool]:
    """Extract page_number, breadcrumb, bbox, and is_table from chunk_text."""
    matches = list(_PAGE_MARKER_RE.finditer(chunk_text))
    page_num = last_known_page
    breadcrumb = last_known_breadcrumb
    bbox: list[float] | None = None
    is_table = False

    if matches:
        last_match = matches[-1]
        try:
            page_num = int(last_match.group(1))
        except (ValueError, IndexError):
            pass
        extra = last_match.group(2) or ""
        b_match = re.search(r"breadcrumb:([^|]+)", extra)
        if b_match:
            breadcrumb = b_match.group(1).strip()
        bbox_match = re.search(r"bbox:([0-9\.,\-]+)", extra)
        if bbox_match:
            try:
                bbox = [float(x.strip()) for x in bbox_match.group(1).split(",")]
            except Exception:
                bbox = None
        if "table:true" in extra.lower() or any(
            "table:true" in m.group(0).lower() for m in matches
        ):
            is_table = True

    # Fallback table detection from markdown table syntax
    if not is_table and (
        "|---" in chunk_text or "|:---" in chunk_text or "| ---" in chunk_text
    ):
        is_table = True

    cleaned = _PAGE_MARKER_RE.sub("", chunk_text).strip()
    return (cleaned or chunk_text.strip()), page_num, breadcrumb, bbox, is_table


def strip_and_resolve_page_number(
    chunk_text: str, last_known_page: int | None = None
) -> tuple[str, int | None]:
    """Backwards-compatible page resolver."""
    cleaned, page_num, _, _, _ = strip_and_resolve_citation_metadata(
        chunk_text, last_known_page
    )
    return cleaned, page_num


def extract_verbatim_quote(query: str, text: str, max_words: int = 35) -> str:
    """Extract the most relevant sub-sentence/sentence verbatim quote matching the query."""
    if not query or not text:
        return ""
    # Split text into sentences
    raw_sentences = re.split(r"(?<=[.!?])\s+|\n+", text)
    sentences = [s.strip() for s in raw_sentences if len(s.strip().split()) >= 4]

    # Filter out Table of Contents rows and pipe-heavy OCR artifacts
    content_sentences = []
    for s in sentences:
        if s.count("|") >= 2 and len(re.findall(r"[a-zA-Z]{3,}", s)) < 6:
            continue
        if ("..." in s or "....." in s) and re.search(r"\d+$", s.strip()):
            continue
        content_sentences.append(s)

    if content_sentences:
        sentences = content_sentences

    if not sentences:
        return text[:150].strip()

    q_words = set(re.findall(r"\w+", query.lower()))
    if not q_words:
        return sentences[0]

    best_sent = sentences[0]
    best_score = -1.0
    for sent in sentences:
        s_words = set(re.findall(r"\w+", sent.lower()))
        overlap = len(q_words & s_words)
        score = overlap / (len(s_words) ** 0.5 + 1.0)
        if score > best_score:
            best_score = score
            best_sent = sent

    tokens = best_sent.split()
    if len(tokens) > max_words:
        return " ".join(tokens[:max_words]) + "..."
    return best_sent
