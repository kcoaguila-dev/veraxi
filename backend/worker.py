import asyncio
import logging

from arq.connections import RedisSettings

from backend.config import get_config
from backend.ingestion.__main__ import run_ingestion

logger = logging.getLogger(__name__)


async def process_ingestion_task(
    ctx,
    text: str,
    tenant_id: str,
    fast_extraction: bool = False,
    language: str = "en",
    custom_stop_words: list | None = None,
    model: str = "gemini-2.5-flash-lite",
    chunk_size: int = 800,
    chunk_overlap: int = 150,
    source: str | None = None,
):
    """
    Background worker task to ingest a document.
    """
    logger.info(f"Worker received ingestion task for tenant {tenant_id}")
    config = get_config()

    import json

    redis = ctx["redis"]
    schema_json = await redis.get(f"tenant:{tenant_id}:schema")

    if not schema_json:
        error_msg = f"Ingestion failed for tenant {tenant_id}: No ontology defined. Please generate a schema in the settings first."
        logger.error(error_msg)
        return {"status": "error", "message": error_msg}

    schema = json.loads(schema_json)

    # run_ingestion is currently synchronous, so we run it in a threadpool to avoid blocking the worker event loop
    loop = asyncio.get_running_loop()
    result = await loop.run_in_executor(
        None,
        run_ingestion,
        config,
        text,
        schema,
        tenant_id,
        fast_extraction,
        language,
        custom_stop_words or [],
        model,
        chunk_size,
        chunk_overlap,
        source,
    )

    logger.info(f"Worker completed ingestion task for tenant {tenant_id}: {result}")
    return result


async def sync_github_repo_task(
    ctx,
    tenant_id: str,
    integration_id: str,
    repos: list,
    include_issues: bool = False,
):
    """Background worker task to sync GitHub repos into the knowledge graph.

    Mirrors process_ingestion_task: the tenant ontology is loaded from
    Redis, and ingestion itself goes through run_ingestion (via
    services/github_sync.py) so Neo4j ↔ Qdrant dual-write is preserved.
    """
    import json

    from supabase import create_client

    from backend.services.github_sync import run_sync_for_integration

    logger.info(f"Worker received GitHub sync task for tenant {tenant_id}")
    config = get_config()
    if not config.supabase_url or not config.supabase_service_key:
        return {"status": "error", "message": "Supabase is not configured"}
    sb = create_client(config.supabase_url, config.supabase_service_key)

    schema = None
    redis = ctx.get("redis") if isinstance(ctx, dict) else None
    if redis is not None:
        schema_json = await redis.get(f"tenant:{tenant_id}:schema")
        if schema_json:
            schema = json.loads(schema_json)
    result = await run_sync_for_integration(
        sb, tenant_id, integration_id, repos, include_issues, schema
    )
    logger.info(f"Worker completed GitHub sync task for tenant {tenant_id}: {result}")
    return result


class WorkerSettings:
    config = get_config()
    redis_settings = RedisSettings.from_dsn(config.redis_url)
    functions = [process_ingestion_task, sync_github_repo_task]  # noqa: RUF012

    # Optional: startup and shutdown logic
    async def on_startup(ctx):
        logger.info("ARQ Worker starting up...")

    async def on_shutdown(ctx):
        logger.info("ARQ Worker shutting down...")
