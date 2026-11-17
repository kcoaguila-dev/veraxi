"""Tests for the artifact Office/PDF export endpoint and builders.

Mirrors test_artifacts_publish.py's dependency_overrides approach:
no live Redis is needed because export is a pure function of the
request body. The builder-level tests open the produced bytes with
python-docx / openpyxl / python-pptx to prove the files are real,
and the SSRF tests prove the PDF renderer's URL fetcher refuses
every non-inline resource.
"""

import io
from unittest.mock import AsyncMock, patch

import pytest
from docx import Document
from fastapi.testclient import TestClient
from openpyxl import load_workbook
from pptx import Presentation
from pptx.util import Inches

from backend.api_gateway import app, get_tenant_id, verify_infrastructure_access
from backend.routes.artifacts import MAX_CODE_CHARS, _safe_export_filename
from backend.services.office_export import (
    BlockedResourceError,
    _blocking_url_fetcher,
    export_pdf,
)

OWNER_TENANT = "owner-tenant"
GUEST_TENANT = "local_guest"

_current_tenant = {"tenant_id": OWNER_TENANT}


@pytest.fixture(autouse=True)
def override_dependencies():
    _current_tenant["tenant_id"] = OWNER_TENANT

    async def override_get_tenant_id():
        return _current_tenant["tenant_id"]

    async def override_verify_infrastructure_access():
        return _current_tenant["tenant_id"]

    app.dependency_overrides[get_tenant_id] = override_get_tenant_id
    app.dependency_overrides[verify_infrastructure_access] = (
        override_verify_infrastructure_access
    )
    yield
    app.dependency_overrides.clear()


@pytest.fixture
def client():
    mock_pool = AsyncMock()
    mock_pool.close = AsyncMock()
    with patch(
        "backend.api_gateway.create_pool", new_callable=AsyncMock
    ) as mock_create_pool:
        mock_create_pool.return_value = mock_pool
        with TestClient(app) as test_client:
            yield test_client


def _export(client, **overrides):
    payload = {
        "format": "pdf",
        "title": "Quarterly Report",
        "content": "# Summary\n\nRevenue grew.\n",
        "content_type": "markdown",
    }
    payload.update(overrides)
    return client.post("/api/artifacts/export", json=payload)


MARKDOWN_WITH_TABLE = (
    "# Budget\n\nIntro line.\n\n"
    "- Apples\n- Oranges\n\n"
    "| Item | Cost |\n| --- | --- |\n| Apples | 3 |\n| Oranges | 4 |\n"
)


# ---------------------------------------------------------------------------
# PDF
# ---------------------------------------------------------------------------


def test_export_pdf_magic_bytes_and_headers(client):
    response = _export(client)
    assert response.status_code == 200
    assert response.content.startswith(b"%PDF-")
    assert "application/pdf" in response.headers["content-type"]
    disposition = response.headers["content-disposition"]
    assert disposition == 'attachment; filename="Quarterly_Report.pdf"'


def test_export_pdf_from_html_and_csv(client):
    html_response = _export(
        client, content="<p>Hello <b>world</b></p>", content_type="html"
    )
    assert html_response.status_code == 200
    assert html_response.content.startswith(b"%PDF-")

    csv_response = _export(
        client, content="A,B\n1,2\n", content_type="csv"
    )
    assert csv_response.status_code == 200
    assert csv_response.content.startswith(b"%PDF-")


# ---------------------------------------------------------------------------
# DOCX
# ---------------------------------------------------------------------------


def test_export_docx_from_markdown(client):
    response = _export(client, format="docx", content=MARKDOWN_WITH_TABLE)
    assert response.status_code == 200
    assert response.content[:2] == b"PK"
    document = Document(io.BytesIO(response.content))
    texts = [paragraph.text for paragraph in document.paragraphs]
    assert "Quarterly Report" in texts
    assert "Intro line." in texts
    assert "Apples" in texts
    assert len(document.tables) == 1
    table = document.tables[0]
    assert table.rows[0].cells[0].text == "Item"
    assert table.rows[1].cells[0].text == "Apples"
    assert table.rows[2].cells[1].text == "4"


def test_export_docx_from_spec(client):
    spec = {
        "sections": [
            {
                "heading": "Findings",
                "level": 1,
                "paragraphs": ["We found things."],
                "bullets": ["First", "Second"],
                "table": {"headers": ["K", "V"], "rows": [["a", "1"]]},
            }
        ]
    }
    response = _export(client, format="docx", content="", spec=spec)
    assert response.status_code == 200
    document = Document(io.BytesIO(response.content))
    texts = [paragraph.text for paragraph in document.paragraphs]
    assert "Findings" in texts
    assert "We found things." in texts
    assert "First" in texts
    assert document.tables[0].rows[1].cells[0].text == "a"


# ---------------------------------------------------------------------------
# XLSX
# ---------------------------------------------------------------------------


def test_export_xlsx_from_spec_preserves_formulas(client):
    spec = {
        "sheets": [
            {
                "name": "Budget",
                "headers": ["Item", "Cost"],
                "rows": [["Apples", 3], ["Oranges", 4], ["Total", "=SUM(B2:B3)"]],
            }
        ]
    }
    response = _export(client, format="xlsx", content="", spec=spec)
    assert response.status_code == 200
    workbook = load_workbook(io.BytesIO(response.content))
    ws = workbook["Budget"]
    assert ws["A1"].value == "Item"
    assert ws["A1"].font.bold is True
    assert ws.freeze_panes == "A2"
    assert ws["B2"].value == 3
    formula_cell = ws["B4"]
    assert formula_cell.value == "=SUM(B2:B3)"
    assert formula_cell.data_type == "f"


def test_export_xlsx_from_markdown_table_and_csv(client):
    response = _export(client, format="xlsx", content=MARKDOWN_WITH_TABLE)
    assert response.status_code == 200
    workbook = load_workbook(io.BytesIO(response.content))
    ws = workbook.active
    assert ws["A1"].value == "Item"
    assert ws["B3"].value == 4

    csv_response = _export(
        client, format="xlsx", content="A,B\n5,6\n", content_type="csv"
    )
    assert csv_response.status_code == 200
    csv_ws = load_workbook(io.BytesIO(csv_response.content)).active
    assert csv_ws["A1"].value == "A"
    assert csv_ws["B2"].value == 6


def test_export_xlsx_from_json_content_spec(client):
    response = _export(
        client,
        format="xlsx",
        content='{"sheets": [{"name": "Data", "headers": ["X"], "rows": [[7]]}]}',
        content_type="json",
    )
    assert response.status_code == 200
    ws = load_workbook(io.BytesIO(response.content))["Data"]
    assert ws["A2"].value == 7


# ---------------------------------------------------------------------------
# PPTX
# ---------------------------------------------------------------------------


def test_export_pptx_from_markdown(client):
    content = "# Intro\n\n- Alpha\n- Beta\n\n---\n\n# Details\n\n- Gamma\n"
    response = _export(client, format="pptx", content=content)
    assert response.status_code == 200
    prs = Presentation(io.BytesIO(response.content))
    assert prs.slide_width == Inches(13.333)
    assert prs.slide_height == Inches(7.5)
    assert len(prs.slides._sldIdLst) == 2
    first_texts = [
        shape.text_frame.text
        for shape in prs.slides[0].shapes
        if shape.has_text_frame
    ]
    assert any("Intro" in text for text in first_texts)
    assert any("Alpha" in text for text in first_texts)


def test_export_pptx_from_spec_with_notes_and_table(client):
    spec = {
        "slides": [
            {
                "title": "Pitch",
                "subtitle": "Series A",
                "bullets": ["Problem", "Solution"],
                "table": {"headers": ["Year", "ARR"], "rows": [["2026", "1M"]]},
                "notes": "Remember the demo.",
            }
        ]
    }
    response = _export(client, format="pptx", content="", spec=spec)
    assert response.status_code == 200
    prs = Presentation(io.BytesIO(response.content))
    slide = prs.slides[0]
    texts = [
        shape.text_frame.text for shape in slide.shapes if shape.has_text_frame
    ]
    assert any("Pitch" in text for text in texts)
    assert any("Series A" in text for text in texts)
    assert any(
        shape.has_table and shape.table.cell(1, 1).text == "1M"
        for shape in slide.shapes
    )
    notes = slide.notes_slide.notes_text_frame.text
    assert "Remember the demo." in notes


# ---------------------------------------------------------------------------
# Validation, size caps, filename safety, guests
# ---------------------------------------------------------------------------


def test_export_rejects_invalid_format_and_content_type(client):
    assert _export(client, format="zip").status_code == 400
    assert _export(client, content_type="yaml").status_code == 400
    assert (
        _export(client, format="xlsx", content="{not json", content_type="json")
        .status_code
        == 400
    )


def test_export_rejects_malformed_spec(client):
    response = _export(client, format="docx", content="", spec={"nope": []})
    assert response.status_code == 400


def test_export_rejects_oversize_content_and_spec(client):
    oversize = "x" * (MAX_CODE_CHARS + 1)
    assert _export(client, content=oversize).status_code == 413
    big_spec = {"sections": [{"heading": "x" * (MAX_CODE_CHARS + 1)}]}
    assert _export(client, format="docx", content="", spec=big_spec).status_code == 413


def test_export_filename_is_sanitized(client):
    response = _export(client, title='../../etc/"evil"name')
    assert response.status_code == 200
    disposition = response.headers["content-disposition"]
    assert ".." not in disposition
    assert "/" not in disposition.split("filename=")[1]
    assert disposition.count('"') == 2

    assert _safe_export_filename('../../a/b"c', "pdf") == "a_b_c.pdf"
    assert _safe_export_filename("", "docx") == "artifact.docx"
    assert _safe_export_filename("///", "xlsx") == "artifact.xlsx"


def test_export_allows_guest_tenant(client):
    _current_tenant["tenant_id"] = GUEST_TENANT
    response = _export(client, format="docx")
    assert response.status_code == 200


# ---------------------------------------------------------------------------
# SSRF: the PDF fetcher fails closed
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "url",
    [
        "http://169.254.169.254/latest/meta-data/",
        "https://example.com/image.png",
        "file:///etc/passwd",
        "ftp://example.com/file",
    ],
)
def test_blocking_url_fetcher_refuses_external_urls(url):
    with pytest.raises(BlockedResourceError):
        _blocking_url_fetcher(url)


def test_blocking_url_fetcher_serves_data_uris():
    result = _blocking_url_fetcher("data:text/plain;base64,aGVsbG8=")
    assert result["string"] == b"hello"
    assert result["mime_type"] == "text/plain"


def test_export_pdf_survives_ssrf_attempt_in_html():
    malicious = (
        '<p>Report</p>'
        '<img src="http://169.254.169.254/latest/meta-data/">'
        '<img src="file:///etc/passwd">'
        '<link rel="stylesheet" href="https://example.com/evil.css">'
    )
    data = export_pdf("T", malicious, content_type="html")
    assert data.startswith(b"%PDF-")
