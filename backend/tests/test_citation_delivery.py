"""End-to-end integration tests for citation delivery and document streaming."""

import os
import urllib.parse
import pytest
from fastapi.testclient import TestClient

from backend.api_gateway import app
from backend.config import get_config
from backend.mcp_server.handlers.tool_registry import (
    _format_mcp_proof_card,
    _resolve_pdf_path,
)


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture
def sample_pdf(tmp_path, monkeypatch):
    """Provides a sample PDF in an approved directory for testing."""
    sample_file = tmp_path / "sample_test_book.pdf"
    # Minimal valid PDF binary header
    sample_file.write_bytes(
        b"%PDF-1.4\n1 0 obj\n<<\n/Type /Catalog\n>>\nendobj\ntrailer\n<<\n>>\n%%EOF"
    )
    monkeypatch.setenv("DOCUMENTS_DIR", str(tmp_path))
    return str(sample_file)


def test_pdf_path_resolution(sample_pdf):
    """Verify that document sources resolve to existing PDF files and prioritize .pdf."""
    resolved = _resolve_pdf_path("sample_test_book")
    assert resolved is not None
    assert os.path.exists(resolved)
    assert resolved.endswith(".pdf")


def test_mcp_proof_card_url_generation(sample_pdf):
    """Verify that MCP hybrid retrieval generates reachable HTTP citation URLs with page anchors."""
    class DummyHit:
        def __init__(self, source, page, text):
            self.payload = {
                "source": source,
                "page_number": page,
                "text": text,
            }

    hits = [
        DummyHit(
            source="sample_test_book",
            page=278,
            text="It was founded by George Williams Jr., who began his career in the FBI.",
        )
    ]

    card = _format_mcp_proof_card("George Williams FBI", hits)
    config = get_config()
    base_api = config.internal_api_url.rstrip("/")

    # Must contain HTTP endpoint rather than raw file://
    assert f"{base_api}/documents/raw?path=" in card
    # Must preserve page anchor for PDF viewer
    assert "#page=278" in card
    assert "George Williams Jr" in card


def test_document_raw_endpoint_serves_pdf(client, sample_pdf):
    """Verify that /api/documents/raw returns 200 OK, application/pdf, and inline disposition."""
    resolved = _resolve_pdf_path("sample_test_book")
    assert resolved is not None

    encoded_path = urllib.parse.quote(os.path.basename(resolved))
    response = client.get(f"/api/documents/raw?path={encoded_path}")

    assert response.status_code == 200
    assert response.headers.get("content-type") == "application/pdf"
    assert "inline;" in response.headers.get("content-disposition", "")
    assert len(response.content) > 0


def test_document_raw_endpoint_security_path_traversal(client):
    """Verify that directory traversal attempts are strictly forbidden with 403."""
    bad_paths = [
        "/etc/passwd",
        "/etc/shadow",
        "../../backend/config.py",
        "/home/ubuntu/.ssh/id_rsa",
    ]

    for p in bad_paths:
        encoded = urllib.parse.quote(p)
        response = client.get(f"/api/documents/raw?path={encoded}")
        assert response.status_code in (403, 404), f"Path {p} was not blocked!"
