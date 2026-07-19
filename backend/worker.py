import asyncio
import logging
from arq.connections import RedisSettings
from backend.config import get_config
from backend.ingestion.__main__ import run_ingestion

logger = logging.getLogger(__name__)

async def process_ingestion_task(ctx, text: str, tenant_id: str):
    """
    Background worker task to ingest a document.
    """
    logger.info(f"Worker received ingestion task for tenant {tenant_id}")
    config = get_config()
    
    # run_ingestion is currently synchronous, so we run it in a threadpool to avoid blocking the worker event loop
    loop = asyncio.get_running_loop()
    result = await loop.run_in_executor(None, run_ingestion, config, text, tenant_id)
    
    logger.info(f"Worker completed ingestion task for tenant {tenant_id}: {result}")
    return result

class WorkerSettings:
    config = get_config()
    redis_settings = RedisSettings.from_dsn(config.redis_url)
    functions = [process_ingestion_task]
    
    # Optional: startup and shutdown logic
    async def on_startup(ctx):
        logger.info("ARQ Worker starting up...")
        
    async def on_shutdown(ctx):
        logger.info("ARQ Worker shutting down...")
