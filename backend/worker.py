import asyncio
import logging
from typing import Any

import sentry_sdk
from arq import cron
from arq.connections import RedisSettings

from backend.config import get_config
from backend.ingestion.__main__ import run_ingestion

logger = logging.getLogger(__name__)

_PAID_PLANS = frozenset({"pro", "team", "enterprise"})
_MAX_INACTIVE_DAYS = 14


def should_run_scheduled_tenant_sync(
    plan: str | None, days_since_active: int | None
) -> bool:
    """Gate scheduled tenant background jobs to active paid plans only.

    Free-tier and dormant (>14d inactive) tenants must trigger scans on-demand
    or via client-side ``vx --local`` so Veraxi never gives away idle compute.
    """
    normalized = (plan or "").strip().lower()
    if normalized not in _PAID_PLANS:
        return False
    return days_since_active is not None and days_since_active <= _MAX_INACTIVE_DAYS


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
    scheduled: bool = False,
    plan: str | None = None,
    days_since_active: int | None = None,
):
    """Background worker task to sync GitHub repos into the knowledge graph.

    Mirrors process_ingestion_task: the tenant ontology is loaded from
    Redis, and ingestion itself goes through run_ingestion (via
    services/github_sync.py) so Neo4j ↔ Qdrant dual-write is preserved.
    When ``scheduled=True``, enforces active paid-plan gating.
    """
    if scheduled and not should_run_scheduled_tenant_sync(plan, days_since_active):
        logger.info(
            "Skipping scheduled GitHub sync for tenant %s (plan=%s, inactive=%s)",
            tenant_id,
            plan,
            days_since_active,
        )
        return {"status": "skipped", "reason": "free_or_dormant_tenant"}
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


async def index_github_app_repo_task(
    ctx,
    tenant_id: str,
    installation_id: int,
    repo_full_name: str,
    branch: str | None = None,
):
    """Background worker task to ephemerally index a GitHub App repository."""
    from supabase import create_client

    from backend.services.github_app_ingest import index_github_app_repo

    config = get_config()
    if not config.supabase_url or not config.supabase_service_key:
        return {"status": "error", "message": "Supabase is not configured"}
    sb = create_client(config.supabase_url, config.supabase_service_key)
    redis = ctx.get("redis") if isinstance(ctx, dict) else None
    return await index_github_app_repo(
        config,
        sb,
        redis,
        tenant_id=tenant_id,
        installation_id=int(installation_id),
        repo_full_name=repo_full_name,
        branch=branch,
    )


async def sync_github_app_push_task(
    ctx,
    installation_id: int,
    repo_full_name: str,
    head_sha: str,
    branch: str | None = None,
):
    """Background worker task to incrementally refresh GitHub App repos on push."""
    from supabase import create_client

    from backend.services import github_app_store as gh_store
    from backend.services.github_app_ingest import update_github_app_repo_incremental

    config = get_config()
    if not config.supabase_url or not config.supabase_service_key:
        return {"status": "error", "message": "Supabase is not configured"}
    sb = create_client(config.supabase_url, config.supabase_service_key)
    redis = ctx.get("redis") if isinstance(ctx, dict) else None
    lock_key = f"ghapp:push-lock:{int(installation_id)}:{repo_full_name}"
    if redis is not None:
        acquired = bool(await redis.set(lock_key, head_sha, nx=True, ex=15))
        if not acquired:
            return {"status": "debounced", "repo": repo_full_name}
    try:
        rows = await asyncio.to_thread(
            gh_store.find_repos_by_installation_and_name,
            sb,
            int(installation_id),
            repo_full_name,
        )
        results: dict[str, Any] = {}
        for row in rows:
            if not row.get("auto_sync_on_push", True):
                continue
            if branch and row.get("default_branch") and branch != row.get("default_branch"):
                continue
            tenant_id = row["tenant_id"]
            try:
                results[tenant_id] = await update_github_app_repo_incremental(
                    config,
                    sb,
                    redis,
                    tenant_id=tenant_id,
                    installation_id=int(installation_id),
                    repo_full_name=repo_full_name,
                    head_sha=head_sha,
                    branch=branch,
                )
            except Exception as exc:
                sentry_sdk.capture_exception(exc)
                results[tenant_id] = {"status": "error", "message": str(exc)}
        return {"status": "ok", "repo": repo_full_name, "results": results}
    finally:
        if redis is not None:
            try:
                await redis.delete(lock_key)
            except Exception as exc:
                sentry_sdk.capture_exception(exc)


async def purge_github_app_repos_task(ctx, targets: list[list[str]]):
    """Background worker task to purge Neo4j code graphs after webhook removal."""
    from backend.services.github_app_ingest import purge_github_app_repo

    purged = 0
    errors: list[str] = []
    for pair in targets:
        if len(pair) != 2:
            continue
        tenant_id, repo_full_name = pair[0], pair[1]
        try:
            await purge_github_app_repo(tenant_id, repo_full_name)
            purged += 1
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            errors.append(f"{tenant_id}/{repo_full_name}: {exc}")
    return {"status": "ok" if not errors else "partial", "purged": purged, "errors": errors}


def _sync_public_vuln_intel() -> dict:
    from backend.ingestion.vuln_intel import fetch_and_write_vuln_intel
    from backend.storage.neo4j_client import Neo4jStorageClient
    from backend.storage.qdrant_client import QdrantStorageClient

    cfg = get_config()
    neo4j = Neo4jStorageClient.from_config(cfg)
    qdrant = None
    try:
        qdrant = QdrantStorageClient.from_config(cfg)
    except Exception as exc:
        logger.warning("Qdrant unavailable for public vuln sync: %s", exc)
    try:
        return fetch_and_write_vuln_intel(
            neo4j, tenant_id="public", qdrant_client=qdrant
        )
    finally:
        neo4j.close()


async def sync_public_vuln_intel_task(ctx):
    """Daily global NVD + KEV + EPSS sync into shared ``public`` graph (0 LLM cost)."""
    try:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(None, _sync_public_vuln_intel)
        logger.info("Public vuln intel sync completed: %s", result)
        return {"status": "ok", **result}
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.error("Public vuln intel sync failed: %s", exc)
        return {"status": "error", "message": str(exc)}


def _sync_public_attack_intel() -> dict:
    from backend.ingestion.attack_intel import (
        fetch_attack_stix,
        parse_attack_stix_payload,
        write_attack_intel,
    )
    from backend.storage.neo4j_client import Neo4jStorageClient
    from backend.storage.qdrant_client import QdrantStorageClient

    cfg = get_config()
    neo4j = Neo4jStorageClient.from_config(cfg)
    qdrant = None
    try:
        qdrant = QdrantStorageClient.from_config(cfg)
    except Exception as exc:
        logger.warning("Qdrant unavailable for public ATT&CK sync: %s", exc)
    try:
        bundle = fetch_attack_stix()
        parsed = parse_attack_stix_payload(bundle)
        return write_attack_intel(
            neo4j, parsed, tenant_id="public", qdrant_client=qdrant
        )
    finally:
        neo4j.close()


async def sync_public_attack_intel_task(ctx):
    """Weekly global MITRE ATT&CK sync into shared ``public`` graph (0 LLM cost)."""
    try:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(None, _sync_public_attack_intel)
        logger.info("Public ATT&CK intel sync completed: %s", result)
        return {"status": "ok", **result}
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        logger.error("Public ATT&CK intel sync failed: %s", exc)
        return {"status": "error", "message": str(exc)}


class WorkerSettings:
    config = get_config()
    redis_settings = RedisSettings.from_dsn(config.redis_url)
    functions = [  # noqa: RUF012
        process_ingestion_task,
        sync_github_repo_task,
        index_github_app_repo_task,
        sync_github_app_push_task,
        purge_github_app_repos_task,
        sync_public_vuln_intel_task,
        sync_public_attack_intel_task,
    ]
    cron_jobs = [  # noqa: RUF012
        cron(sync_public_vuln_intel_task, hour=3, minute=0, run_at_startup=False),
        cron(
            sync_public_attack_intel_task,
            weekday=0,
            hour=4,
            minute=0,
            run_at_startup=False,
        ),
    ]

    # Optional: startup and shutdown logic
    async def on_startup(ctx):
        logger.info("ARQ Worker starting up...")

    async def on_shutdown(ctx):
        logger.info("ARQ Worker shutting down...")
