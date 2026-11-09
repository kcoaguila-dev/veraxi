"""File attachment endpoints — upload, list, delete."""

import asyncio
import json
import logging
import os
import uuid
from pathlib import Path

import magic
import sentry_sdk
from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["files"])

MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024  # 25 MB


from backend.ingestion.document_parser import (
    extract_attachment_text as _extract_attachment_text,
)


def _is_safe_document_path(target_path: str) -> bool:
    """Verifies that the target path is resolved and strictly inside approved document directories."""
    resolved_path = os.path.realpath(target_path)
    allowed_candidates = [
        os.path.join(os.getcwd(), "uploads"),
        os.path.join(os.getcwd(), "seed"),
        "/app/data",
        os.path.expanduser("~/Documents/book"),
        "/home/ubuntu/Documents/book",
    ]
    custom_dir = os.environ.get("DOCUMENTS_DIR")
    if custom_dir:
        allowed_candidates.append(custom_dir)

    allowed_dirs = {os.path.realpath(d) for d in allowed_candidates if os.path.exists(d)}
    return any(
        resolved_path.startswith(d + os.sep) or resolved_path == d
        for d in allowed_dirs
    )


def _detect_pdf_content(file_path: str) -> bool:
    """Checks if a file is a PDF via extension or magic bytes."""
    if file_path.lower().endswith(".pdf"):
        return True
    try:
        with open(file_path, "rb") as f:
            header = f.read(5)
            return header.startswith(b"%PDF-")
    except Exception:
        return False


def register_file_routes(
    app_router, get_tenant_id, verify_infrastructure_access, limiter, config
):
    """Register all file routes with injected auth dependencies."""

    @app_router.api_route("/api/documents/raw", methods=["GET", "HEAD"])
    async def view_raw_document(path: str, request: Request):
        """Streams an on-disk document for inline browser/webview viewing.

        Enforces directory whitelisting, detects PDF headers for extensionless files,
        and sets Content-Disposition inline so browsers render with #page=N support.
        """
        if not path:
            raise HTTPException(status_code=400, detail="Document path required")

        resolved_path = os.path.realpath(path)
        if not os.path.isfile(resolved_path):
            try:
                from backend.mcp_server.handlers.tool_registry import _resolve_pdf_path

                cand = _resolve_pdf_path(path)
                if cand and os.path.isfile(cand):
                    resolved_path = os.path.realpath(cand)
            except Exception as e:
                logger.debug(f"Fuzzy resolution failed for {path}: {e}")

        if not _is_safe_document_path(resolved_path):
            raise HTTPException(
                status_code=403, detail="Access to specified path is forbidden"
            )

        if not os.path.isfile(resolved_path):
            raise HTTPException(status_code=404, detail="Document not found")

        is_pdf = _detect_pdf_content(resolved_path)
        media_type = "application/pdf" if is_pdf else "application/octet-stream"
        filename = os.path.basename(resolved_path)
        if is_pdf and not filename.lower().endswith(".pdf"):
            filename = f"{filename}.pdf"

        return FileResponse(
            path=resolved_path,
            media_type=media_type,
            headers={
                "Content-Disposition": f'inline; filename="{filename}"',
                "Access-Control-Allow-Origin": "*",
            },
        )

    @app_router.post("/api/chat/upload_attachment")
    async def upload_attachment(
        request: Request,
        file: UploadFile = File(...),  # noqa: B008
        tenant_id: str = Depends(get_tenant_id),
    ):
        try:
            os.makedirs("uploads", exist_ok=True)
            file_id = str(uuid.uuid4())
            _, file_extension = os.path.splitext(file.filename or "")
            file_path = os.path.join("uploads", f"{file_id}{file_extension}")

            chunks = []
            total_size = 0
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                total_size += len(chunk)
                if total_size > MAX_ATTACHMENT_BYTES:
                    raise HTTPException(
                        status_code=413,
                        detail=f"File too large (max {MAX_ATTACHMENT_BYTES // (1024 * 1024)}MB)",
                    )
                chunks.append(chunk)
            content = b"".join(chunks)

            await asyncio.to_thread(Path(file_path).write_bytes, content)
            file_size = len(content)
            import time

            file_metadata = {
                "id": file_id,
                "filename": file.filename,
                "size": file_size,
                "date": int(time.time()),
                "path": file_path,
            }
            await request.app.state.redis.hset(
                f"tenant:{tenant_id}:files", file_id, json.dumps(file_metadata)
            )
            mime_type = await asyncio.to_thread(magic.from_file, file_path, mime=True)
            extracted_text = await asyncio.to_thread(
                _extract_attachment_text,
                file_path,
                file.filename,
                content,
                mime_type,
                parser=config.document_parser,
            )
            return {"text": extracted_text, "file_id": file_id}
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Error uploading attachment: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.get("/api/chat/files")
    async def get_files(request: Request, tenant_id: str = Depends(get_tenant_id)):
        try:
            files_dict = await request.app.state.redis.hgetall(
                f"tenant:{tenant_id}:files"
            )
            return {
                "files": [
                    json.loads(fmeta.decode("utf-8")) for fmeta in files_dict.values()
                ]
            }
        except Exception as e:
            logger.error(f"Error getting files: {e}")
            return {"files": []}

    @app_router.delete("/api/chat/files/{file_id}")
    async def delete_file(
        file_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)
    ):
        try:
            file_meta_raw = await request.app.state.redis.hget(
                f"tenant:{tenant_id}:files", file_id
            )
            if file_meta_raw:
                file_meta = json.loads(file_meta_raw.decode("utf-8"))
                target_path = file_meta.get("path")
                if target_path:
                    abs_target = os.path.abspath(target_path)
                    uploads_dir = os.path.abspath("uploads")
                    if abs_target.startswith(uploads_dir + os.sep) and os.path.exists(
                        abs_target
                    ):
                        await asyncio.to_thread(os.remove, abs_target)
                await request.app.state.redis.hdel(f"tenant:{tenant_id}:files", file_id)
            return {"success": True}
        except Exception as e:
            logger.error(f"Error deleting file: {e}")
            raise HTTPException(status_code=500, detail=str(e))
