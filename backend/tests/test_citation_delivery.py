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


def test_resolve_pdf_path_rejects_paths_outside_allowed_dirs():
    """_resolve_pdf_path must not resolve arbitrary absolute system paths."""
    assert _resolve_pdf_path("/etc/passwd") is None
    assert _resolve_pdf_path("/etc/hostname") is None


def test_document_raw_endpoint_blocks_symlink_escape(client, tmp_path, monkeypatch):
    """A symlink inside DOCUMENTS_DIR pointing outside must not be served."""
    outside = tmp_path / "outside"
    outside.mkdir()
    secret = outside / "secret_book.pdf"
    secret.write_bytes(b"%PDF-1.4\nSECRET-OUTSIDE-CONTENT")
    docs_dir = tmp_path / "docs"
    docs_dir.mkdir()
    (docs_dir / "linked_book.pdf").symlink_to(secret)
    monkeypatch.setenv("DOCUMENTS_DIR", str(docs_dir))

    response = client.get(
        "/api/documents/raw", params={"path": "linked_book.pdf"}
    )
    assert response.status_code in (403, 404)
    assert b"SECRET-OUTSIDE-CONTENT" not in response.content


def test_document_raw_endpoint_blocks_encoded_traversal(client, sample_pdf):
    """Encoded traversal (%2F) must be blocked, not decoded into an escape."""
    response = client.get(
        "/api/documents/raw",
        params={"path": "..%2F..%2Fbackend%2Fconfig.py"},
    )
    assert response.status_code in (403, 404)

    response = client.get(
        f"/api/documents/raw?path={urllib.parse.quote('../../etc/passwd')}"
    )
    assert response.status_code in (403, 404)
    assert b"root:" not in response.content


def test_document_raw_endpoint_blocks_documents_dir_itself(client, sample_pdf, tmp_path):
    """Requesting the DOCUMENTS_DIR directory itself must be blocked."""
    response = client.get(
        "/api/documents/raw", params={"path": str(tmp_path)}
    )
    assert response.status_code in (403, 404)


def test_document_raw_endpoint_serves_extensionless_pdf(client, tmp_path, monkeypatch):
    """An extensionless file with PDF magic bytes inside an allowed dir is served."""
    extless = tmp_path / "extensionless_book"
    extless.write_bytes(b"%PDF-1.4\n1 0 obj\n<<\n/Type /Catalog\n>>\nendobj\n%%EOF")
    monkeypatch.setenv("DOCUMENTS_DIR", str(tmp_path))

    response = client.get(
        "/api/documents/raw", params={"path": "extensionless_book"}
    )
    assert response.status_code == 200
    assert response.headers.get("content-type") == "application/pdf"
    assert len(response.content) > 0


def test_document_raw_endpoint_rejects_dot_and_traversal_fuzzy_fallback(
    client, sample_pdf
):
    """path='.' and traversal paths like '../sample_test_book.pdf' must not fuzzy-match."""
    assert _resolve_pdf_path(".") is None
    assert _resolve_pdf_path("...") is None

    dot_response = client.get("/api/documents/raw", params={"path": "."})
    assert dot_response.status_code in (403, 404)

    traversal_response = client.get(
        "/api/documents/raw", params={"path": "../sample_test_book.pdf"}
    )
    assert traversal_response.status_code == 403
