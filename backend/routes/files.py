"""File attachment endpoints — upload, list, delete."""

import json
import logging
import os
import uuid

import magic
import sentry_sdk
from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["files"])


from backend.ingestion.document_parser import (
    extract_attachment_text as _extract_attachment_text,
)


def register_file_routes(
    app_router, get_tenant_id, verify_infrastructure_access, limiter, config
):
    """Register all file routes with injected auth dependencies."""

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
            content = await file.read()
            with open(file_path, "wb") as f:  # noqa: ASYNC230
                f.write(content)
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
            mime_type = magic.from_file(file_path, mime=True)
            extracted_text = _extract_attachment_text(
                file_path,
                file.filename,
                content,
                mime_type,
                parser=config.document_parser,
            )
            return {"text": extracted_text, "file_id": file_id}
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
                if "path" in file_meta and os.path.exists(file_meta["path"]):
                    os.remove(file_meta["path"])
                await request.app.state.redis.hdel(f"tenant:{tenant_id}:files", file_id)
            return {"success": True}
        except Exception as e:
            logger.error(f"Error deleting file: {e}")
            raise HTTPException(status_code=500, detail=str(e))
