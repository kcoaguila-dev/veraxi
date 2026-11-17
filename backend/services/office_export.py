"""Deterministic Office / PDF exporters for chat artifacts.

Backs ``POST /api/artifacts/export``: an artifact's Markdown / HTML /
CSV / JSON-spec content is converted to PDF, DOCX, XLSX, or PPTX
bytes with WeasyPrint, python-docx, openpyxl, and python-pptx.

Security posture: nothing here executes artifact content. The
converters only *parse* Markdown/CSV/JSON specs and render them with
the document libraries, and the PDF renderer's URL fetcher refuses
every network or local-file fetch (see :func:`_blocking_url_fetcher`),
so an artifact cannot make the server fetch internal URLs (SSRF)
while it is being exported.

All four builders are pure functions returning ``bytes`` so they can
be unit-tested without the HTTP layer.
"""

import csv
import html as html_module
import io
import json
import re

import markdown as markdown_lib
from docx import Document
from docx.document import Document as DocxDocument
from docx.shared import Pt
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill
from openpyxl.utils import get_column_letter
from pptx import Presentation
from pptx.util import Inches, Pt as PptxPt

# ---------------------------------------------------------------------------
# Shared Markdown parsing
#
# One small line-based parser feeds the DOCX and PPTX builders (the
# PDF path uses the `markdown` library instead, which produces real
# HTML). Blocks are plain dicts:
#   {"kind": "heading", "level": int, "text": str}
#   {"kind": "paragraph", "text": str}
#   {"kind": "bullets", "ordered": bool, "items": [str]}
#   {"kind": "code", "text": str}
#   {"kind": "table", "headers": [str], "rows": [[str]]}
#   {"kind": "divider"}
# ---------------------------------------------------------------------------

_HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
_BULLET_RE = re.compile(r"^\s*[-*+]\s+(.*)$")
_NUMBERED_RE = re.compile(r"^\s*\d+[.)]\s+(.*)$")
_TABLE_SEPARATOR_RE = re.compile(r"^\s*\|?[\s:|-]+\|?\s*$")
_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_NUMBER_RE = re.compile(r"^-?\d+(\.\d+)?$")


def _strip_inline(text: str) -> str:
    """Reduce inline Markdown to plain text for Word/PowerPoint,
    which receive styled runs rather than Markdown source."""
    text = _LINK_RE.sub(r"\1", text)
    text = text.replace("**", "").replace("__", "")
    text = text.replace("*", "").replace("`", "")
    return text.strip()


def _split_table_row(line: str) -> list[str]:
    stripped = line.strip().strip("|")
    return [cell.strip() for cell in stripped.split("|")]


def _is_table_start(lines: list[str], index: int) -> bool:
    if index + 1 >= len(lines):
        return False
    if "|" not in lines[index]:
        return False
    separator = lines[index + 1]
    return bool(_TABLE_SEPARATOR_RE.match(separator)) and "-" in separator


def _parse_table(lines: list[str], index: int) -> tuple[dict, int]:
    headers = _split_table_row(lines[index])
    rows: list[list[str]] = []
    index += 2  # header + separator
    while index < len(lines) and "|" in lines[index] and lines[index].strip():
        rows.append(_split_table_row(lines[index]))
        index += 1
    return {"kind": "table", "headers": headers, "rows": rows}, index


def parse_markdown_blocks(content: str) -> list[dict]:
    """Parse Markdown source into the block list described above."""
    lines = content.replace("\r\n", "\n").split("\n")
    blocks: list[dict] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        if stripped.startswith("```"):
            code_lines: list[str] = []
            index += 1
            while index < len(lines) and not lines[index].strip().startswith("```"):
                code_lines.append(lines[index])
                index += 1
            index += 1  # closing fence (or EOF)
            blocks.append({"kind": "code", "text": "\n".join(code_lines)})
            continue
        if not stripped:
            index += 1
            continue
        if stripped in ("---", "***", "___"):
            blocks.append({"kind": "divider"})
            index += 1
            continue
        heading = _HEADING_RE.match(stripped)
        if heading:
            blocks.append(
                {
                    "kind": "heading",
                    "level": len(heading.group(1)),
                    "text": _strip_inline(heading.group(2)),
                }
            )
            index += 1
            continue
        if _is_table_start(lines, index):
            table, index = _parse_table(lines, index)
            blocks.append(table)
            continue
        bullet = _BULLET_RE.match(line)
        numbered = _NUMBERED_RE.match(line)
        if bullet or numbered:
            items: list[str] = []
            ordered = numbered is not None
            pattern = _NUMBERED_RE if ordered else _BULLET_RE
            while index < len(lines):
                match = pattern.match(lines[index])
                if not match:
                    break
                items.append(_strip_inline(match.group(1)))
                index += 1
            blocks.append({"kind": "bullets", "ordered": ordered, "items": items})
            continue
        blocks.append({"kind": "paragraph", "text": _strip_inline(stripped)})
        index += 1
    return blocks


def _parse_csv_rows(content: str) -> list[list[str]]:
    reader = csv.reader(io.StringIO(content))
    return [row for row in reader if any(cell.strip() for cell in row)]


def _extract_tables(content: str) -> list[dict]:
    """All Markdown tables in *content*, in order."""
    return [b for b in parse_markdown_blocks(content) if b["kind"] == "table"]


def spec_to_markdown(spec: dict) -> str:
    """Render a JSON export spec as Markdown so the PDF builder (and
    any Markdown-only path) can consume specs too. Supports the
    section, slide, and sheet shapes used by the other builders."""
    parts: list[str] = []
    for section in spec.get("sections") or []:
        level = int(section.get("level") or 1)
        heading = section.get("heading") or ""
        if heading:
            parts.append("#" * max(1, min(6, level)) + f" {heading}")
        for paragraph in section.get("paragraphs") or []:
            parts.append(str(paragraph))
        for bullet in section.get("bullets") or []:
            parts.append(f"- {bullet}")
        table = section.get("table")
        if table:
            parts.append(_table_to_markdown(table))
    for slide in spec.get("slides") or []:
        parts.append(f"# {slide.get('title') or ''}")
        if slide.get("subtitle"):
            parts.append(str(slide["subtitle"]))
        for bullet in slide.get("bullets") or []:
            parts.append(f"- {bullet}")
        if slide.get("table"):
            parts.append(_table_to_markdown(slide["table"]))
        parts.append("---")
    for sheet in spec.get("sheets") or []:
        parts.append(f"# {sheet.get('name') or 'Sheet'}")
        headers = sheet.get("headers") or []
        rows = sheet.get("rows") or []
        if headers or rows:
            parts.append(
                _table_to_markdown({"headers": headers, "rows": rows})
            )
    return "\n\n".join(part for part in parts if part)


def _table_to_markdown(table: dict) -> str:
    headers = [str(h) for h in table.get("headers") or []]
    lines = []
    if headers:
        lines.append("| " + " | ".join(headers) + " |")
        lines.append("| " + " | ".join("---" for _ in headers) + " |")
    for row in table.get("rows") or []:
        lines.append("| " + " | ".join(str(cell) for cell in row) + " |")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# PDF (WeasyPrint)
# ---------------------------------------------------------------------------

_PRINT_STYLESHEET = """
@page {
  size: A4;
  margin: 2cm 1.8cm;
  @bottom-center {
    content: counter(page) " / " counter(pages);
    font-family: sans-serif;
    font-size: 9pt;
    color: #64748B;
  }
}
body {
  font-family: sans-serif;
  font-size: 11pt;
  line-height: 1.5;
  color: #1E293B;
}
h1 { font-size: 20pt; margin: 0 0 12pt 0; }
h2 { font-size: 15pt; margin-top: 18pt; }
h3 { font-size: 12.5pt; margin-top: 14pt; }
table { border-collapse: collapse; width: 100%; margin: 10pt 0; }
th, td { border: 1px solid #CBD5E1; padding: 4pt 6pt; text-align: left; }
th { background: #F1F5F9; }
pre {
  background: #F8FAFC;
  border: 1px solid #E2E8F0;
  padding: 8pt;
  font-size: 9.5pt;
  white-space: pre-wrap;
  word-wrap: break-word;
}
code { font-family: monospace; font-size: 9.5pt; }
a { color: #2563EB; }
img { max-width: 100%; }
"""


class BlockedResourceError(ValueError):
    """Raised by the PDF URL fetcher for any non-inline resource."""


def _blocking_url_fetcher(url: str) -> dict:
    """Resolve a resource URL for the PDF renderer, failing closed:
    only ``data:`` URIs (already inline in the document) are served;
    every ``http://`` / ``https://`` / ``file://`` / other fetch is
    refused so artifact HTML cannot reach the network or the local
    disk. Kept as a plain function so tests can assert the block
    directly."""
    if url.startswith("data:"):
        return _data_uri_result(url)
    raise BlockedResourceError(f"External resource blocked during PDF export: {url}")


class _BlockingURLFetcher:
    """WeasyPrint ``url_fetcher`` adapter over
    :func:`_blocking_url_fetcher` (WeasyPrint 70 fetchers are
    callables returning ``URLFetcherResponse``; a blocked URL raises,
    which WeasyPrint turns into a skipped resource, never a fetch)."""

    _fail_on_errors = False

    def __call__(self, url: str):
        from weasyprint.urls import URLFetcherResponse

        result = _blocking_url_fetcher(url)
        return URLFetcherResponse(
            url, result["string"], {"Content-Type": result["mime_type"]}
        )


def _data_uri_result(url: str) -> dict:
    header, _, payload = url.partition(",")
    mime_type = header[5:].split(";")[0] or "application/octet-stream"
    if ";base64" in header:
        import base64

        return {"string": base64.b64decode(payload), "mime_type": mime_type}
    from urllib.parse import unquote_to_bytes

    return {"string": unquote_to_bytes(payload), "mime_type": mime_type}


def _markdown_to_html(content: str) -> str:
    return markdown_lib.markdown(
        content, extensions=["tables", "fenced_code", "sane_lists"]
    )


def _csv_to_html(content: str) -> str:
    rows = _parse_csv_rows(content)
    if not rows:
        return ""
    head = "".join(
        f"<th>{html_module.escape(cell)}</th>" for cell in rows[0]
    )
    body = "".join(
        "<tr>"
        + "".join(f"<td>{html_module.escape(cell)}</td>" for cell in row)
        + "</tr>"
        for row in rows[1:]
    )
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


def _content_to_html(content: str, content_type: str) -> str:
    if content_type == "html":
        return content
    if content_type == "csv":
        return _csv_to_html(content)
    if content_type == "json":
        try:
            parsed = json.loads(content)
        except ValueError:
            parsed = None
        if isinstance(parsed, dict):
            return _markdown_to_html(spec_to_markdown(parsed))
        return f"<pre>{html_module.escape(content)}</pre>"
    return _markdown_to_html(content)


def export_pdf(title: str, content: str, content_type: str = "markdown") -> bytes:
    """Render *content* (Markdown by default, or raw HTML / CSV /
    JSON spec) to a print-styled PDF via WeasyPrint. No external
    resource is ever fetched: see :func:`_blocking_url_fetcher`."""
    from weasyprint import HTML

    body_html = _content_to_html(content, content_type)
    document = (
        "<!DOCTYPE html>\n<html>\n<head>\n"
        '<meta charset="utf-8">\n'
        f"<title>{html_module.escape(title)}</title>\n"
        f"<style>{_PRINT_STYLESHEET}</style>\n"
        "</head>\n<body>\n"
        f"<h1>{html_module.escape(title)}</h1>\n"
        f"{body_html}\n"
        "</body>\n</html>\n"
    )
    return HTML(string=document, url_fetcher=_BlockingURLFetcher()).write_pdf()


# ---------------------------------------------------------------------------
# DOCX (python-docx)
# ---------------------------------------------------------------------------


def _docx_add_table(document: DocxDocument, headers: list, rows: list) -> None:
    table = document.add_table(rows=1, cols=len(headers) or 1)
    table.style = "Table Grid"
    if headers:
        for cell, header in zip(table.rows[0].cells, headers, strict=False):
            cell.text = ""
            run = cell.paragraphs[0].add_run(str(header))
            run.bold = True
    for row in rows:
        cells = table.add_row().cells
        for cell, value in zip(cells, row, strict=False):
            cell.text = str(value)


def _docx_add_block(document: DocxDocument, block: dict) -> None:
    kind = block["kind"]
    if kind == "heading":
        document.add_heading(block["text"], level=min(block["level"], 4))
    elif kind == "paragraph":
        document.add_paragraph(block["text"])
    elif kind == "bullets":
        style = "List Number" if block["ordered"] else "List Bullet"
        for item in block["items"]:
            document.add_paragraph(item, style=style)
    elif kind == "code":
        paragraph = document.add_paragraph()
        run = paragraph.add_run(block["text"])
        run.font.name = "Consolas"
        run.font.size = Pt(9)
    elif kind == "table":
        _docx_add_table(document, block["headers"], block["rows"])
    # Dividers have no Word equivalent worth emitting.


def _docx_add_section(document: DocxDocument, section: dict) -> None:
    heading = section.get("heading")
    if heading:
        document.add_heading(
            str(heading), level=max(1, min(4, int(section.get("level") or 1)))
        )
    for paragraph in section.get("paragraphs") or []:
        document.add_paragraph(str(paragraph))
    for bullet in section.get("bullets") or []:
        document.add_paragraph(str(bullet), style="List Bullet")
    table = section.get("table")
    if table:
        _docx_add_table(
            document, table.get("headers") or [], table.get("rows") or []
        )


def export_docx(title: str, content: str, spec: dict | None = None) -> bytes:
    """Build a Word document from a structured *spec*
    (``{"sections": [...]}``) when given, otherwise from Markdown
    *content* (headings, lists, code blocks, tables)."""
    document = Document()
    document.core_properties.title = title
    if title:
        document.add_heading(title, level=0)
    if spec is not None:
        sections = spec.get("sections")
        if not isinstance(sections, list):
            raise ValueError("spec must contain a 'sections' list")
        for section in sections:
            _docx_add_section(document, section)
    else:
        for block in parse_markdown_blocks(content):
            _docx_add_block(document, block)
    buffer = io.BytesIO()
    document.save(buffer)
    return buffer.getvalue()


# ---------------------------------------------------------------------------
# XLSX (openpyxl)
# ---------------------------------------------------------------------------

_HEADER_FILL = PatternFill(start_color="D9E2F3", end_color="D9E2F3", fill_type="solid")
_HEADER_FONT = Font(bold=True)
_MAX_COLUMN_WIDTH = 50


def _cell_value(value):
    """Preserve Excel formulas (strings starting with ``=``) verbatim
    and convert numeric-looking strings to numbers so formulas over
    spec data actually compute; everything else stays a string."""
    if isinstance(value, (int, float)):
        return value
    text = str(value)
    if text.startswith("="):
        return text
    if _NUMBER_RE.match(text.strip()):
        return float(text) if "." in text else int(text)
    return text


def _xlsx_write_sheet(ws, headers: list, rows: list) -> None:
    if headers:
        ws.append([str(header) for header in headers])
        for cell in ws[1]:
            cell.font = _HEADER_FONT
            cell.fill = _HEADER_FILL
    for row in rows:
        ws.append([_cell_value(value) for value in row])
    ws.freeze_panes = "A2"
    _xlsx_autofit(ws)


def _xlsx_autofit(ws) -> None:
    for column in ws.columns:
        letter = get_column_letter(column[0].column)
        longest = max((len(str(cell.value)) for cell in column if cell.value is not None), default=0)
        ws.column_dimensions[letter].width = min(max(longest + 2, 8), _MAX_COLUMN_WIDTH)


def _xlsx_sheets_from_content(content: str) -> list[tuple[str, list, list]]:
    tables = _extract_tables(content)
    if tables:
        return [
            (f"Sheet{index + 1}", table["headers"], table["rows"])
            for index, table in enumerate(tables)
        ]
    rows = _parse_csv_rows(content)
    if rows:
        return [("Sheet1", rows[0], rows[1:])]
    lines = [line for line in content.split("\n") if line.strip()]
    return [("Sheet1", [], [[line] for line in lines])]


def export_xlsx(title: str, content: str, spec: dict | None = None) -> bytes:
    """Build a workbook from a structured *spec*
    (``{"sheets": [{"name", "headers", "rows"}]}``) when given,
    otherwise from Markdown tables or CSV in *content*. Header rows
    are bold/shaded, the top row is frozen, and ``=``-prefixed
    strings are stored as live Excel formulas."""
    workbook = Workbook()
    if spec is not None:
        sheets = spec.get("sheets")
        if not isinstance(sheets, list) or not sheets:
            raise ValueError("spec must contain a non-empty 'sheets' list")
        sheet_defs = [
            (
                str(sheet.get("name") or f"Sheet{index + 1}"),
                sheet.get("headers") or [],
                sheet.get("rows") or [],
            )
            for index, sheet in enumerate(sheets)
        ]
    else:
        sheet_defs = _xlsx_sheets_from_content(content)
    for index, (name, headers, rows) in enumerate(sheet_defs):
        ws = workbook.active if index == 0 else workbook.create_sheet()
        ws.title = name[:31]
        _xlsx_write_sheet(ws, headers, rows)
    workbook.properties.title = title
    buffer = io.BytesIO()
    workbook.save(buffer)
    return buffer.getvalue()


# ---------------------------------------------------------------------------
# PPTX (python-pptx)
# ---------------------------------------------------------------------------

_SLIDE_WIDTH = Inches(13.333)
_SLIDE_HEIGHT = Inches(7.5)


def _pptx_add_textbox(slide, left, top, width, height):
    box = slide.shapes.add_textbox(left, top, width, height)
    box.text_frame.word_wrap = True
    return box.text_frame


def _pptx_fill_bullets(frame, bullets: list, font_size: int = 18) -> None:
    frame.word_wrap = True
    for index, bullet in enumerate(bullets):
        paragraph = frame.paragraphs[0] if index == 0 else frame.add_paragraph()
        paragraph.text = str(bullet)
        paragraph.font.size = PptxPt(font_size)
        paragraph.level = 0


def _pptx_add_table(slide, table: dict) -> None:
    headers = [str(h) for h in table.get("headers") or []]
    rows = table.get("rows") or []
    row_count = len(rows) + (1 if headers else 0)
    col_count = max(len(headers), *(len(row) for row in rows), 1)
    shape = slide.shapes.add_table(
        row_count, col_count, Inches(0.6), Inches(2.2), Inches(12.1), Inches(3.5)
    )
    grid = shape.table
    offset = 0
    if headers:
        for col, header in enumerate(headers):
            cell = grid.cell(0, col)
            cell.text = header
            for paragraph in cell.text_frame.paragraphs:
                for run in paragraph.runs:
                    run.font.bold = True
        offset = 1
    for row_index, row in enumerate(rows):
        for col, value in enumerate(row):
            grid.cell(row_index + offset, col).text = str(value)


def _pptx_add_slide(prs, title_text: str, subtitle, bullets: list, table, notes) -> None:
    slide = prs.slides.add_slide(prs.slide_layouts[6])  # blank
    title_frame = _pptx_add_textbox(
        slide, Inches(0.6), Inches(0.3), Inches(12.1), Inches(1.0)
    )
    title_frame.paragraphs[0].text = title_text
    title_frame.paragraphs[0].font.size = PptxPt(32)
    title_frame.paragraphs[0].font.bold = True
    top = 1.4
    if subtitle:
        subtitle_frame = _pptx_add_textbox(
            slide, Inches(0.6), Inches(top), Inches(12.1), Inches(0.6)
        )
        subtitle_frame.paragraphs[0].text = str(subtitle)
        subtitle_frame.paragraphs[0].font.size = PptxPt(20)
        top = 2.1
    if bullets:
        body = _pptx_add_textbox(
            slide, Inches(0.6), Inches(top), Inches(12.1), Inches(4.8)
        )
        _pptx_fill_bullets(body, bullets)
    if table:
        _pptx_add_table(slide, table)
    if notes:
        slide.notes_slide.notes_text_frame.text = str(notes)


def _pptx_slides_from_markdown(content: str) -> list[dict]:
    """Split Markdown on ``---`` dividers: each chunk's first heading
    is the slide title, its bullets the body."""
    slides: list[dict] = []
    current: dict = {"title": "", "bullets": [], "table": None}
    for block in parse_markdown_blocks(content):
        if block["kind"] == "divider":
            if current["title"] or current["bullets"] or current["table"]:
                slides.append(current)
            current = {"title": "", "bullets": [], "table": None}
        elif block["kind"] == "heading" and not current["title"]:
            current["title"] = block["text"]
        elif block["kind"] == "heading":
            current["bullets"].append(block["text"])
        elif block["kind"] == "bullets":
            current["bullets"].extend(block["items"])
        elif block["kind"] == "paragraph":
            current["bullets"].append(block["text"])
        elif block["kind"] == "table":
            current["table"] = {"headers": block["headers"], "rows": block["rows"]}
        elif block["kind"] == "code":
            current["bullets"].append(block["text"])
    if current["title"] or current["bullets"] or current["table"]:
        slides.append(current)
    return slides


def export_pptx(title: str, content: str, spec: dict | None = None) -> bytes:
    """Build a 16:9 deck from a structured *spec*
    (``{"slides": [{"title", "subtitle", "bullets", "table",
    "notes"}]}``) when given, otherwise from Markdown *content*
    split on ``---`` slide dividers."""
    prs = Presentation()
    prs.slide_width = _SLIDE_WIDTH
    prs.slide_height = _SLIDE_HEIGHT
    if spec is not None:
        slides = spec.get("slides")
        if not isinstance(slides, list) or not slides:
            raise ValueError("spec must contain a non-empty 'slides' list")
        slide_defs = [
            (
                str(slide.get("title") or ""),
                slide.get("subtitle"),
                slide.get("bullets") or [],
                slide.get("table"),
                slide.get("notes"),
            )
            for slide in slides
        ]
    else:
        slide_defs = [
            (
                slide["title"] or title,
                None,
                slide["bullets"],
                slide["table"],
                None,
            )
            for slide in _pptx_slides_from_markdown(content)
        ]
        if not slide_defs:
            slide_defs = [(title, None, [], None, None)]
    for slide_title, subtitle, bullets, table, notes in slide_defs:
        _pptx_add_slide(prs, slide_title, subtitle, bullets, table, notes)
    prs.core_properties.title = title
    buffer = io.BytesIO()
    prs.save(buffer)
    return buffer.getvalue()
