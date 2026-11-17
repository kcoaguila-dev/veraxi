"""Tests for the ``create_office_artifact`` chat tool (Phase 3).

The tool validates a document spec/content by running the pure
builders in backend/services/office_export.py and returns a fenced
```json envelope block. These tests prove the whole loop at the
seams: tool -> block -> POST /api/artifacts/export (the exact
request the Flutter panel sends for a JSON artifact) -> a real,
openable Office/PDF file — plus the fail-closed behavior for
malformed, oversize, and mismatched calls.
"""

import io
import json
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient
from openpyxl import load_workbook
from pptx import Presentation

from backend.api_gateway import app, get_tenant_id, verify_infrastructure_access
from backend.mcp_server.tool_dispatch import _execute_single_tool, get_tools
from backend.routes.artifacts import MAX_CODE_CHARS

OWNER_TENANT = "owner-tenant"

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


PITCH_DECK_SPEC = {
    "slides": [
        {"title": "Vision", "subtitle": "Series A", "bullets": ["Problem", "Fix"]},
        {"title": "Market", "bullets": ["TAM is large"]},
        {"title": "Product", "bullets": ["Demo"]},
        {"title": "Traction", "bullets": ["Growing"]},
        {"title": "Ask", "bullets": ["$2M"], "notes": "Close strong."},
    ]
}

BUDGET_SPEC = {
    "sheets": [
        {
            "name": "Budget",
            "headers": ["Item", "Cost"],
            "rows": [["Rent", 1200], ["Food", 600], ["Total", "=SUM(B2:B3)"]],
        }
    ]
}


def _call_tool(**tool_input):
    hits, graph_hits = _execute_single_tool(
        "create_office_artifact", tool_input, OWNER_TENANT
    )
    assert graph_hits == []
    assert len(hits) == 1
    return hits[0].payload


def _envelope_from_payload(payload) -> dict:
    """Extract and parse the canonical block exactly as a client
    would: the fenced ```json body of ``artifact_block``."""
    block = payload["artifact_block"]
    assert block.startswith("```json\n")
    assert block.endswith("\n```")
    return json.loads(block[len("```json\n") : -len("\n```")])


def _export_block(client, envelope, fmt):
    """POST the block the way the Flutter panel exports a JSON
    artifact: the raw block JSON as content with content_type json,
    the format the user picked in the Export menu."""
    return client.post(
        "/api/artifacts/export",
        json={
            "format": fmt,
            "title": envelope["title"],
            "content": json.dumps(envelope),
            "content_type": "json",
        },
    )


# ---------------------------------------------------------------------------
# Tool definition & gating
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_tool_is_offered_by_default():
    # No toggles set: the tool executes nothing and calls nothing
    # external, so it is not gated behind tool_settings.
    tools = await get_tools({})
    names = [t["function"]["name"] for t in tools]
    assert "create_office_artifact" in names
    tool = next(t for t in tools if t["function"]["name"] == "create_office_artifact")
    params = tool["function"]["parameters"]
    assert params["properties"]["format"]["enum"] == ["pdf", "docx", "xlsx", "pptx"]
    assert "=SUM" in tool["function"]["description"]


# ---------------------------------------------------------------------------
# End-to-end: tool block -> export endpoint -> real file
# ---------------------------------------------------------------------------


def test_pptx_pitch_deck_end_to_end(client):
    payload = _call_tool(format="pptx", title="Pitch Deck", spec=PITCH_DECK_SPEC)
    assert "error" not in payload
    envelope = _envelope_from_payload(payload)
    assert envelope["format"] == "pptx"
    assert envelope["title"] == "Pitch Deck"
    assert envelope["slides"] == PITCH_DECK_SPEC["slides"]

    response = _export_block(client, envelope, "pptx")
    assert response.status_code == 200
    prs = Presentation(io.BytesIO(response.content))
    assert len(prs.slides._sldIdLst) == 5
    first_texts = [
        shape.text_frame.text
        for shape in prs.slides[0].shapes
        if shape.has_text_frame
    ]
    assert any("Vision" in text for text in first_texts)


def test_xlsx_budget_formulas_end_to_end(client):
    payload = _call_tool(format="xlsx", title="Budget", spec=BUDGET_SPEC)
    assert "error" not in payload
    envelope = _envelope_from_payload(payload)
    # The formula survives the tool's canonical re-serialization.
    assert envelope["sheets"][0]["rows"][2][1] == "=SUM(B2:B3)"

    response = _export_block(client, envelope, "xlsx")
    assert response.status_code == 200
    ws = load_workbook(io.BytesIO(response.content))["Budget"]
    assert ws["B2"].value == 1200
    formula_cell = ws["B4"]
    assert formula_cell.value == "=SUM(B2:B3)"
    assert formula_cell.data_type == "f"


def test_pdf_from_markdown_content_end_to_end(client):
    payload = _call_tool(
        format="pdf",
        title="Status Report",
        content="# Status\n\nAll green.\n",
        content_type="markdown",
    )
    assert "error" not in payload
    envelope = _envelope_from_payload(payload)
    assert envelope["content"] == "# Status\n\nAll green.\n"

    response = _export_block(client, envelope, "pdf")
    assert response.status_code == 200
    assert response.content.startswith(b"%PDF-")
    # The envelope title drives the attachment name even though the
    # request itself carried it too.
    assert (
        response.headers["content-disposition"]
        == 'attachment; filename="Status_Report.pdf"'
    )


def test_content_envelope_title_fallback(client):
    # A content envelope posted without a request title still names
    # the file from the envelope (the unwrap path in the route).
    payload = _call_tool(
        format="docx", title="Field Notes", content="# Notes\n\nText.\n"
    )
    envelope = _envelope_from_payload(payload)
    response = client.post(
        "/api/artifacts/export",
        json={
            "format": "docx",
            "title": "",
            "content": json.dumps(envelope),
            "content_type": "json",
        },
    )
    assert response.status_code == 200
    assert (
        response.headers["content-disposition"]
        == 'attachment; filename="Field_Notes.docx"'
    )


def test_spec_envelope_exported_via_explicit_spec(client):
    # The Flutter provider sends the stripped spec payload explicitly;
    # that path must produce the same file as the raw-block path.
    payload = _call_tool(format="pptx", title="Pitch Deck", spec=PITCH_DECK_SPEC)
    envelope = _envelope_from_payload(payload)
    spec = {
        k: v
        for k, v in envelope.items()
        if k not in ("format", "title", "content", "content_type")
    }
    response = client.post(
        "/api/artifacts/export",
        json={
            "format": "pptx",
            "title": "Pitch Deck",
            "content": "",
            "content_type": "json",
            "spec": spec,
        },
    )
    assert response.status_code == 200
    prs = Presentation(io.BytesIO(response.content))
    assert len(prs.slides._sldIdLst) == 5


@pytest.mark.asyncio
async def test_tool_result_reaches_llm_context():
    from backend.mcp_server.tool_dispatch import execute_tools_internal

    context_str, merged = await execute_tools_internal(
        [
            {
                "name": "create_office_artifact",
                "args": {
                    "format": "pptx",
                    "title": "Pitch Deck",
                    "spec": PITCH_DECK_SPEC,
                },
                "id": "1",
            }
        ],
        OWNER_TENANT,
        {},
    )
    assert "```json" in context_str
    assert "Pitch Deck" in context_str
    assert merged


# ---------------------------------------------------------------------------
# Adversarial: every failure is a structured error, never a crash
# ---------------------------------------------------------------------------


def _assert_structured_error(payload):
    assert "error" in payload
    assert "artifact_block" not in payload


def test_unknown_format_fails_closed():
    _assert_structured_error(_call_tool(format="zip", title="X", spec=PITCH_DECK_SPEC))


def test_missing_title_fails_closed():
    _assert_structured_error(_call_tool(format="pptx", spec=PITCH_DECK_SPEC))
    _assert_structured_error(
        _call_tool(format="pptx", title="  ", spec=PITCH_DECK_SPEC)
    )


def test_neither_spec_nor_content_fails_closed():
    _assert_structured_error(_call_tool(format="xlsx", title="Empty"))


def test_spec_not_an_object_fails_closed():
    _assert_structured_error(
        _call_tool(format="pptx", title="X", spec="slides go here")
    )


def test_slides_not_a_list_fails_closed():
    _assert_structured_error(
        _call_tool(format="pptx", title="X", spec={"slides": "five of them"})
    )
    _assert_structured_error(
        _call_tool(format="pptx", title="X", spec={"slides": []})
    )


def test_malformed_sheet_entries_fail_closed():
    _assert_structured_error(
        _call_tool(format="xlsx", title="X", spec={"sheets": ["not-a-sheet"]})
    )
    _assert_structured_error(
        _call_tool(format="xlsx", title="X", spec={"sheets": []})
    )


def test_docx_spec_without_sections_fails_closed():
    _assert_structured_error(
        _call_tool(format="docx", title="X", spec={"slides": [{"title": "A"}]})
    )


def test_oversize_content_and_spec_fail_closed():
    oversize = "x" * (MAX_CODE_CHARS + 1)
    _assert_structured_error(
        _call_tool(format="pdf", title="X", content=oversize)
    )
    big_spec = {"sections": [{"heading": oversize}]}
    _assert_structured_error(_call_tool(format="docx", title="X", spec=big_spec))


def test_content_type_mismatch_fails_closed():
    _assert_structured_error(
        _call_tool(
            format="pdf", title="X", content="# Hi", content_type="yaml"
        )
    )
    _assert_structured_error(
        _call_tool(
            format="pdf", title="X", content="# Hi", content_type="json"
        )
    )


def test_title_too_long_fails_closed():
    _assert_structured_error(
        _call_tool(format="pdf", title="t" * 301, content="# Hi")
    )


def test_pptx_slide_theme_and_accent_color_round_trip(client):
    themed_spec = {
        "slides": [
            {"title": "Hello", "theme": "dark", "accent_color": "#D98A2B"},
            {"title": "World", "theme": "light", "accent_color": "#D98A2B"},
        ]
    }
    payload = _call_tool(format="pptx", title="Hello World", spec=themed_spec)
    envelope = _envelope_from_payload(payload)
    assert envelope["slides"][0]["theme"] == "dark"
    assert envelope["slides"][1]["theme"] == "light"

    resp = _export_block(client, envelope, "pptx")
    assert resp.status_code == 200
    prs = Presentation(io.BytesIO(resp.content))
    assert len(prs.slides) == 2
    assert prs.slides[0].background.fill.fore_color.rgb is not None
    assert prs.slides[1].background.fill.fore_color.rgb is not None
    assert "Hello" in "\n".join(
        shape.text for shape in prs.slides[0].shapes if shape.has_text_frame
    )
    assert "World" in "\n".join(
        shape.text for shape in prs.slides[1].shapes if shape.has_text_frame
    )
