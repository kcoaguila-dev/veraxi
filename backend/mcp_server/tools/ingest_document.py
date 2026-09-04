import os
from typing import Any

import httpx


def mcp_ingest_document(
    tenant_id: str,
    file_path: str | None = None,
    url: str | None = None,
    fast_extraction: bool = False,
    language: str = "en",
    model: str = "gemini-2.5-flash-lite",
    custom_stop_words: str = "",
    chunk_size: int = 200,
    chunk_overlap: int = 50,
    wait_for_completion: bool = False
) -> dict[str, Any]:
    """
    Submits a document or URL to Veraxi's native ingestion pipeline.
    
    Args:
        tenant_id: The tenant ID (auto-populated by context).
        file_path: Absolute path to a local file (e.g., PDF, MD, TXT).
        url: URL to scrape (if file_path is not provided).
        fast_extraction: Whether to use fast extraction.
        language: Language for extraction.
        model: Model for extraction.
        custom_stop_words: Comma-separated list of stop words.
        
    Returns:
        A dictionary containing the status and job_id.
    """
    if not file_path and not url:
        return {"error": "Must provide either file_path or url."}

    # Internal API url for the web server
    api_base = "http://localhost:8000/api"

    headers = {
        "x-tenant-id": tenant_id
    }

    try:
        if file_path:
            if not os.path.exists(file_path):
                return {"error": f"File not found: {file_path}"}
            
            with open(file_path, 'rb') as f:
                files = {'file': (os.path.basename(file_path), f)}
                data = {
                    'fast_extraction': str(fast_extraction).lower(),
                    'language': language,
                    'model': model,
                    'custom_stop_words': custom_stop_words,
                    'chunk_size': str(chunk_size),
                    'chunk_overlap': str(chunk_overlap)
                }
                
                # We use a synchronous httpx Client because MCP tools run synchronously
                # and MCP server handles async execution wrapper.
                with httpx.Client(timeout=300) as client:
                    response = client.post(
                        f"{api_base}/admin/ingest/upload",
                        files=files,
                        data=data,
                        headers=headers
                    )
        else:
            json_data = {
                'url': url,
                'fast_extraction': fast_extraction,
                'language': language,
                'custom_stop_words': [w.strip() for w in custom_stop_words.split(",")] if custom_stop_words else [],
                'chunk_size': chunk_size,
                'chunk_overlap': chunk_overlap
            }
            with httpx.Client(timeout=300) as client:
                response = client.post(
                    f"{api_base}/admin/ingest/url",
                    json=json_data,
                    headers=headers
                )

        response.raise_for_status()
        result = response.json()
        
        if wait_for_completion and "job_id" in result:
            import time
            job_id = result["job_id"]
            while True:
                time.sleep(5)
                status_res = mcp_get_ingest_status(tenant_id, job_id)
                if status_res.get("status") not in ["queued", "in_progress", "deferred"]:
                    return status_res
                    
        return result
    except httpx.HTTPError as e:
        response_text = e.response.text if getattr(e, 'response', None) else None
        return {"error": f"HTTP Error during ingestion: {e!s}", "details": response_text}
    except Exception as e:  # noqa: BLE001
        return {"error": f"Unexpected error: {e!s}"}

def mcp_get_ingest_status(tenant_id: str, job_id: str) -> dict[str, Any]:
    """
    Polls the status of an active ingestion job.
    """
    api_base = "http://localhost:8000/api"
    headers = {
        "x-tenant-id": tenant_id
    }
    
    try:
        with httpx.Client(timeout=10) as client:
            response = client.get(f"{api_base}/admin/ingest/status/{job_id}", headers=headers)
            response.raise_for_status()
            return response.json()
    except httpx.HTTPError as e:
        return {"error": f"HTTP Error checking status: {e!s}"}
    except Exception as e:  # noqa: BLE001
        return {"error": f"Unexpected error: {e!s}"}
