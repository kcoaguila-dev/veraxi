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


# ---------------------------------------------------------------------------
# Deterministic delivery in call_model (Phase 1 guarantee)
#
# The LLM only has to call the tool / write a summary — the exact block
# must reach the final AIMessage even when the model omits, alters, or
# never calls the tool at all (prose slides).
# ---------------------------------------------------------------------------

from unittest.mock import MagicMock

from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

from backend.mcp_server.orchestrator import (
    _detect_office_artifact_intent,
    _ensure_office_artifact_blocks,
    _parse_markdown_slides,
    call_model,
)


@pytest.fixture
def mock_orchestrator_config():
    with patch("backend.mcp_server.orchestrator.get_config") as mock_get_config:
        mock_conf = MagicMock()
        mock_conf.llm_api_key = "test_key"
        mock_conf.llm_model_name = "test_model"
        mock_conf.llm_base_url = "http://test"
        mock_get_config.return_value = mock_conf
        yield mock_conf


def _office_block():
    payload = _call_tool(format="pptx", title="Hello World", spec=PITCH_DECK_SPEC)
    return payload["artifact_block"]


def test_slide_intent_detection_matches_creation_requests_only():
    assert (
        _detect_office_artifact_intent(
            [HumanMessage(content="create a slide deck about Q3 results")]
        )
        == "pptx"
    )
    assert (
        _detect_office_artifact_intent(
            [HumanMessage(content="make a presentation for the board")]
        )
        == "pptx"
    )
    assert (
        _detect_office_artifact_intent(
            [HumanMessage(content="give me a simple slide that says hello")]
        )
        == "pptx"
    )
    assert (
        _detect_office_artifact_intent(
            [HumanMessage(content="export this as pptx please")]
        )
        == "pptx"
    )
    # Questions about slides are not creation intent.
    assert (
        _detect_office_artifact_intent(
            [HumanMessage(content="what is a slide deck?")]
        )
        is None
    )
    assert (
        _detect_office_artifact_intent(
            [HumanMessage(content="explain recursion with an example")]
        )
        is None
    )


def test_ensure_blocks_appends_exact_block_when_llm_omits_it():
    block = _office_block()
    result = _ensure_office_artifact_blocks("Your deck is ready.", [block])
    assert result == f"Your deck is ready.\n\n{block}"


def test_ensure_blocks_replaces_altered_envelope_with_exact_block():
    block = _office_block()
    altered = block.replace("Vision", "Hallucinated")
    assert altered != block
    result = _ensure_office_artifact_blocks(f"Done.\n\n{altered}", [block])
    assert "Hallucinated" not in result
    assert result.count("```json") == 1
    assert block in result


def test_ensure_blocks_keeps_verbatim_block_unchanged():
    block = _office_block()
    content = f"Your deck is ready.\n\n{block}"
    assert _ensure_office_artifact_blocks(content, [block]) == content


def test_parse_markdown_slides_requires_two_slides():
    assert _parse_markdown_slides("Slide 1: Only\n\nHello") is None
    slides = _parse_markdown_slides(
        "## Slide 1: Hello\n\n- Welcome\n\n## Slide 2 — World\n\n- Bye\n- Later"
    )
    assert slides == [
        {"title": "Hello", "bullets": ["Welcome"]},
        {"title": "World", "bullets": ["Bye", "Later"]},
    ]


async def _run_call_model(response, messages, tools=None):
    plain_llm = AsyncMock()
    plain_llm.ainvoke.return_value = response
    plain_llm.bind_tools = MagicMock(return_value=plain_llm)
    with (
        patch(
            "backend.mcp_server.orchestrator._create_chat_llm",
            return_value=plain_llm,
        ),
        patch(
            "backend.mcp_server.orchestrator.get_tools",
            new=AsyncMock(return_value=tools or []),
        ),
    ):
        state = {"messages": messages, "calculate_grounding": False}
        result = await call_model(state)
    return result["messages"][0], plain_llm


@pytest.mark.asyncio
async def test_call_model_reattaches_tool_block_omitted_by_llm(
    mock_orchestrator_config,
):
    block = _office_block()
    tool_message = ToolMessage(
        content="Here is the context retrieved from the database:\n",
        tool_call_id="call-1",
        artifact=[
            {
                "id": "office_artifact",
                "payload": {"artifact_block": block},
                "sources": ["Office Artifact"],
            }
        ],
    )
    message, _ = await _run_call_model(
        AIMessage(content="Your deck is ready — enjoy!"),
        [HumanMessage(content="make a presentation"), tool_message],
    )
    assert block in message.content
    assert message.content.startswith("Your deck is ready")


@pytest.mark.asyncio
async def test_call_model_converts_prose_slides_to_artifact_block(
    mock_orchestrator_config,
):
    prose = (
        "Slide 1: Hello\n\nWelcome to the talk.\n\n"
        "Slide 2: World\n\n- Point A\n- Point B"
    )
    message, _ = await _run_call_model(
        AIMessage(content=prose),
        [HumanMessage(content="create a slide deck")],
    )
    assert "```json" in message.content
    envelope = json.loads(
        message.content.split("```json\n", 1)[1].split("\n```", 1)[0]
    )
    assert envelope["format"] == "pptx"
    assert [s["title"] for s in envelope["slides"]] == ["Hello", "World"]
    assert envelope["slides"][1]["bullets"] == ["Point A", "Point B"]
    # The prose outline is collapsed to the concise summary; its lines
    # survive only as slide bullets inside the JSON spec.
    assert "Your 2-slide deck is ready" in message.content
    assert envelope["slides"][0]["bullets"] == ["Welcome to the talk."]
    assert message.content.index("Welcome to the talk.") > message.content.index(
        "```json"
    )


@pytest.mark.asyncio
async def test_call_model_injects_slide_directive_when_intent_detected(
    mock_orchestrator_config,
):
    tools = [
        {
            "type": "function",
            "function": {
                "name": "create_office_artifact",
                "description": "build a document",
                "parameters": {"type": "object", "properties": {}},
            },
        }
    ]
    _, plain_llm = await _run_call_model(
        AIMessage(content="ok"),
        [HumanMessage(content="create a slide deck about sales")],
        tools=tools,
    )
    sent = plain_llm.ainvoke.call_args.args[0]
    system_text = "\n".join(
        str(m.content) for m in sent if m.__class__.__name__ == "SystemMessage"
    )
    assert "create_office_artifact" in system_text
    assert "MUST call" in system_text
    # The artifacts_enabled note no longer conflicts: it reserves raw
    # fenced blocks for UI/code/diagrams and routes documents to the tool.
    state = {
        "messages": [HumanMessage(content="hi")],
        "calculate_grounding": False,
        "tool_settings": {"artifacts_enabled": True},
    }
    plain_llm2 = AsyncMock()
    plain_llm2.ainvoke.return_value = AIMessage(content="ok")
    plain_llm2.bind_tools = MagicMock(return_value=plain_llm2)
    with (
        patch(
            "backend.mcp_server.orchestrator._create_chat_llm",
            return_value=plain_llm2,
        ),
        patch(
            "backend.mcp_server.orchestrator.get_tools",
            new=AsyncMock(return_value=[]),
        ),
    ):
        await call_model(state)
    sent2 = plain_llm2.ainvoke.call_args.args[0]
    note_text = "\n".join(str(m.content) for m in sent2)
    assert "create_office_artifact" in note_text
    assert "Reserve raw fenced" in note_text


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
