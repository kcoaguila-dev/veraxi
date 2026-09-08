"""File attachment endpoints — upload, list, delete."""

import json
import logging
import os
import uuid

import magic
import sentry_sdk
from docling.document_converter import DocumentConverter
from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["files"])


def register_file_routes(app_router, get_tenant_id, verify_infrastructure_access, limiter, config):
    """Register all file routes with injected auth dependencies."""

    @app_router.post("/api/chat/upload_attachment")
    async def upload_attachment(request: Request, file: UploadFile = File(...), tenant_id: str = Depends(get_tenant_id)):  # noqa: B008
        try:
            os.makedirs("uploads", exist_ok=True)
            file_id = str(uuid.uuid4())
            _, file_extension = os.path.splitext(file.filename)
            file_path = os.path.join("uploads", f"{file_id}{file_extension}")
            content = await file.read()
            with open(file_path, "wb") as f:  # noqa: ASYNC230
                f.write(content)
            file_size = len(content)
            import time
            file_metadata = {"id": file_id, "filename": file.filename, "size": file_size, "date": int(time.time()), "path": file_path}
            await request.app.state.redis.hset(f"tenant:{tenant_id}:files", file_id, json.dumps(file_metadata))
            mime_type = magic.from_file(file_path, mime=True)
            extracted_text = f"File {file.filename} uploaded."
            if mime_type.startswith("text/") or mime_type in ["application/json", "application/csv"]:
                try:
                    extracted_text = content.decode("utf-8")
                except Exception as e:  # noqa: BLE001
                    logger.warning("Failed to decode text/csv file content: %s", repr(e))
                    sentry_sdk.capture_exception(e)
            else:
                try:
                    converter = DocumentConverter()
                    result = converter.convert(file_path)
                    extracted_text = result.document.export_to_markdown()
                except Exception as e:  # noqa: BLE001
                    logger.warning(f"Docling could not convert {file.filename}: {e}")
            return {"text": extracted_text, "file_id": file_id}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error uploading attachment: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.get("/api/chat/files")
    async def get_files(request: Request, tenant_id: str = Depends(get_tenant_id)):
        try:
            files_dict = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:files")
            return {"files": [json.loads(fmeta.decode("utf-8")) for fmeta in files_dict.values()]}
        except Exception as e:  # noqa: BLE001
            logger.error(f"Error getting files: {e}")
            return {"files": []}

    @app_router.delete("/api/chat/files/{file_id}")
    async def delete_file(file_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
        try:
            file_meta_raw = await request.app.state.redis.hget(f"tenant:{tenant_id}:files", file_id)
            if file_meta_raw:
                file_meta = json.loads(file_meta_raw.decode("utf-8"))
                if "path" in file_meta and os.path.exists(file_meta["path"]):
                    os.remove(file_meta["path"])
                await request.app.state.redis.hdel(f"tenant:{tenant_id}:files", file_id)
            return {"success": True}
        except Exception as e:  # noqa: BLE001
            logger.error(f"Error deleting file: {e}")
            raise HTTPException(status_code=500, detail=str(e))
