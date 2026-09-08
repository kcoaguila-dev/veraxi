"""Ingestion endpoints — text, file upload, URL, schema management, and memory."""

import json
import logging
import os
import tempfile

import magic
import sentry_sdk
from backend.config import get_config
from backend.storage.quota import check_tenant_hard_cap
from docling.document_converter import DocumentConverter
from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from pydantic import BaseModel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["ingestion"])


class IngestRequest(BaseModel):
    text: str
    fast_extraction: bool = False
    language: str = "en"
    custom_stop_words: list[str] = []


class MemoryIngestRequest(BaseModel):
    content: str
    model: str | None = None
    api_key: str | None = None
    base_url: str | None = None


class UrlIngestRequest(BaseModel):
    url: str
    fast_extraction: bool = False
    language: str = "en"
    custom_stop_words: list[str] = []
    model: str = "gemini-2.5-flash-lite"
    chunk_size: int = 200
    chunk_overlap: int = 50


class SchemaDefinition(BaseModel):
    entities: list[str]
    relations: dict[str, dict[str, list[str]]]


class AutoGenerateSchemaRequest(BaseModel):
    description: str
    temperature: float = 0.3
    max_entities: int = 6
    max_relations: int = 10


async def _ensure_schema_exists(redis, tenant_id: str, sample_text: str):
    schema_json = await redis.get(f"tenant:{tenant_id}:schema")
    if schema_json:
        return
    logger.info(f"No schema found for tenant {tenant_id}. Auto-generating from ingested content...")
    config = get_config()
    from backend.prompts import get_auto_ontology_prompt
    from openai import AsyncOpenAI
    client = AsyncOpenAI(**config.get_llm_client_args())
    try:
        prompt = get_auto_ontology_prompt(6, 10)
        snippet = sample_text[:3000]
        response = await client.chat.completions.create(
            model=config.llm_model_name,
            messages=[{"role": "system", "content": prompt}, {"role": "user", "content": f"Generate a schema for the following text:\n\n{snippet}"}],
            response_format={"type": "json_object"},
            temperature=0.3
        )
        content = response.choices[0].message.content
        await redis.set(f"tenant:{tenant_id}:schema", content)
        logger.info(f"Auto-generated and saved schema for tenant {tenant_id}.")
    except Exception as e:  # noqa: BLE001
        logger.error(f"Failed to auto-generate schema: {e}")


_ALLOWED_MIMES = [
    "application/pdf", "text/plain", "text/markdown", "text/html",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/msword",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-excel",
    "image/png", "image/jpeg", "image/tiff", "image/bmp",
]


def register_ingestion_routes(app_router, get_tenant_id, verify_infrastructure_access, limiter, config):
    """Register all ingestion routes with injected auth dependencies."""

    @app_router.post("/api/admin/ingest")
    @limiter.limit(config.rate_limit_ingest)
    async def ingest_data(request: Request, ingest_request: IngestRequest, tenant_id: str = Depends(verify_infrastructure_access)):
        try:
            check_tenant_hard_cap(tenant_id, get_config())
            await _ensure_schema_exists(request.app.state.redis, tenant_id, ingest_request.text)
            job = await request.app.state.redis.enqueue_job("process_ingestion_task", ingest_request.text, tenant_id, ingest_request.fast_extraction, ingest_request.language, ingest_request.custom_stop_words)
            return {"status": "queued", "job_id": job.job_id}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error during ingestion: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.post("/api/memory/ingest")
    @limiter.limit(config.rate_limit_ingest)
    async def ingest_memory(request: Request, memory_request: MemoryIngestRequest, tenant_id: str = Depends(verify_infrastructure_access)):
        try:
            check_tenant_hard_cap(tenant_id, get_config())
            content_with_tag = f"The following is a verified long-term memory fact to be saved about the user:\n{memory_request.content}"
            await _ensure_schema_exists(request.app.state.redis, tenant_id, content_with_tag)
            model_name = memory_request.model or "gemini-2.5-flash-lite"
            job = await request.app.state.redis.enqueue_job("process_ingestion_task", content_with_tag, tenant_id, False, "en", None, model_name)
            return {"status": "queued", "job_id": job.job_id}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error during memory ingestion: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.post("/api/admin/ingest/upload")
    @limiter.limit(config.rate_limit_ingest)
    async def ingest_upload(request: Request, file: UploadFile = File(...), fast_extraction: bool = Form(False), language: str = Form("en"), custom_stop_words: str = Form(""), model: str = Form("gemini-2.5-flash-lite"), chunk_size: int = Form(200), chunk_overlap: int = Form(50), tenant_id: str = Depends(get_tenant_id)):  # noqa: B008
        try:
            check_tenant_hard_cap(tenant_id, get_config())
            MAX_FILE_SIZE = 50 * 1024 * 1024
            size = 0
            _, file_extension = os.path.splitext(file.filename)
            with tempfile.NamedTemporaryFile(delete=False, suffix=file_extension) as tmp_file:
                while chunk := await file.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_FILE_SIZE:
                        os.unlink(tmp_file.name)
                        raise HTTPException(status_code=413, detail="File exceeds the 50MB maximum upload limit. Please upload a smaller file.")
                    tmp_file.write(chunk)
                tmp_path = tmp_file.name
            mime_type = magic.from_file(tmp_path, mime=True)
            if mime_type not in _ALLOWED_MIMES:
                os.unlink(tmp_path)
                logger.warning(f"File upload blocked. Invalid magic bytes detected: {mime_type} for file {file.filename}")
                raise HTTPException(status_code=400, detail="Invalid file type. Supported formats: PDF, Word, PowerPoint, Excel, HTML, Text, and Images (PNG/JPG).")
            logger.info(f"Converting file {file.filename} with Docling...")
            converter = DocumentConverter()
            result = converter.convert(tmp_path)
            markdown_text = result.document.export_to_markdown()
            os.unlink(tmp_path)
            logger.info(f"Enqueueing {len(markdown_text)} bytes of markdown from {file.filename}")
            parsed_stop_words = [w.strip() for w in custom_stop_words.split(",")] if custom_stop_words else []
            await _ensure_schema_exists(request.app.state.redis, tenant_id, markdown_text)
            job = await request.app.state.redis.enqueue_job("process_ingestion_task", markdown_text, tenant_id, fast_extraction, language, parsed_stop_words, model, chunk_size, chunk_overlap)
            return {"status": "queued", "job_id": job.job_id}
        except HTTPException:
            raise
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error during file ingestion: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.post("/api/admin/ingest/url")
    @limiter.limit(config.rate_limit_ingest)
    async def ingest_url(request: Request, url_request: UrlIngestRequest, tenant_id: str = Depends(verify_infrastructure_access)):
        try:
            check_tenant_hard_cap(tenant_id, get_config())
            logger.info(f"Converting URL {url_request.url} with Docling...")
            converter = DocumentConverter()
            result = converter.convert(url_request.url)
            markdown_text = result.document.export_to_markdown()
            logger.info(f"Enqueueing {len(markdown_text)} bytes of markdown from {url_request.url}")
            await _ensure_schema_exists(request.app.state.redis, tenant_id, markdown_text)
            job = await request.app.state.redis.enqueue_job("process_ingestion_task", markdown_text, tenant_id, url_request.fast_extraction, url_request.language, url_request.custom_stop_words, url_request.model, url_request.chunk_size, url_request.chunk_overlap)
            return {"status": "queued", "job_id": job.job_id}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error during URL ingestion: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.get("/api/admin/ingest/status/{job_id}")
    async def get_ingest_status(request: Request, job_id: str, tenant_id: str = Depends(verify_infrastructure_access)):
        from arq.jobs import Job, JobStatus
        redis = request.app.state.redis
        job = Job(job_id, redis)
        status = await job.status()
        if status == JobStatus.not_found:
            raise HTTPException(status_code=404, detail="Job not found")
        result_data = None
        if status == JobStatus.complete:
            info = await job.result_info()
            if info and not info.success:
                return {"status": "error", "error": str(info.result)}
            if info and info.success:
                result_data = info.result
                if isinstance(result_data, dict) and result_data.get("status") == "error":
                    return {"status": "error", "error": result_data.get("message", "Unknown error")}
        return {"status": status.value if hasattr(status, 'value') else str(status), "result": result_data}

    @app_router.get("/api/admin/schema")
    async def get_schema(request: Request, tenant_id: str = Depends(verify_infrastructure_access)):
        schema = await request.app.state.redis.get(f"tenant:{tenant_id}:schema")
        if schema:
            return json.loads(schema)
        raise HTTPException(status_code=404, detail="No schema defined for this tenant.")

    @app_router.post("/api/admin/schema")
    async def set_schema(request: Request, schema: SchemaDefinition, tenant_id: str = Depends(verify_infrastructure_access)):
        await request.app.state.redis.set(f"tenant:{tenant_id}:schema", schema.model_dump_json())
        return {"status": "success"}

    @app_router.post("/api/admin/schema/auto-generate")
    async def auto_generate_schema(data: AutoGenerateSchemaRequest):
        config = get_config()
        from backend.prompts import get_auto_ontology_prompt
        from openai import AsyncOpenAI
        client = AsyncOpenAI(**config.get_llm_client_args())
        try:
            prompt = get_auto_ontology_prompt(data.max_entities, data.max_relations)
            response = await client.chat.completions.create(
                model=config.llm_model_name,
                messages=[{"role": "system", "content": prompt}, {"role": "user", "content": data.description}],
                response_format={"type": "json_object"},
                temperature=data.temperature
            )
            return json.loads(response.choices[0].message.content)
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail=f"Failed to generate valid schema: {e!s}")
