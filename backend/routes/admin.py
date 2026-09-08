"""Admin endpoints — stats, models, config, health."""

import logging
import os
import re

import httpx
import sentry_sdk
from backend.config import get_config
from backend.models_config import DEFAULT_PROVIDER_MODELS
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient
from fastapi import APIRouter, Depends, HTTPException

logger = logging.getLogger(__name__)

router = APIRouter(tags=["admin"])

# Simple cache for models
_models_cache: dict = {}
_models_cache_time: float = 0


def register_admin_routes(app_router, get_tenant_id, verify_infrastructure_access, limiter, config):
    """Register all admin routes with injected auth dependencies."""

    @app_router.get("/api/admin/stats")
    def get_stats(tenant_id: str = Depends(verify_infrastructure_access)):
        try:
            config = get_config()
            qdrant = QdrantStorageClient.from_config(config)
            neo4j = Neo4jStorageClient.from_config(config)
            stats = {}
            try:
                from qdrant_client.http import models
                filter = models.Filter(must=[models.FieldCondition(key="tenant_id", match=models.MatchValue(value=tenant_id))])
                qdrant_points = qdrant.client.count(collection_name=config.qdrant_collection_name, count_filter=filter)
                vector_count = qdrant_points.count
                stats["qdrant_points"] = vector_count
            except Exception as e:  # noqa: BLE001
                sentry_sdk.capture_exception(e)
                logger.warning(f"Failed to get qdrant stats: {e}")
                vector_count = 0
            try:
                records = neo4j.execute_read("MATCH (n) WHERE n.tenant_id = $tenant_id RETURN count(n) AS count", parameters={"tenant_id": tenant_id})
                node_count = records[0]["count"] if records else 0
            except Exception as e:  # noqa: BLE001
                sentry_sdk.capture_exception(e)
                logger.warning(f"Failed to get neo4j stats: {e}")
                node_count = 0
            finally:
                neo4j.close()
            return {"node_count": node_count, "vector_count": vector_count, "tenant_id": tenant_id}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error getting stats: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.get("/api/models")
    async def get_models():
        """Returns available models, dynamically fetching from providers when possible."""
        global _models_cache, _models_cache_time
        import time
        if time.time() - _models_cache_time < 300 and _models_cache:
            return _models_cache
        config = get_config()
        models_dict = dict(DEFAULT_PROVIDER_MODELS)
        if config.llm_api_key and (not config.llm_base_url or "openai" in config.llm_base_url.lower()):
            try:
                async with httpx.AsyncClient() as client:
                    headers = {"Authorization": f"Bearer {config.llm_api_key}"}
                    if os.environ.get("OPENAI_ORGANIZATION"):
                        headers["OpenAI-Organization"] = os.environ.get("OPENAI_ORGANIZATION")
                    base_url = (config.llm_base_url or "https://api.openai.com/v1").rstrip("/")
                    response = await client.get(f"{base_url}/models", headers=headers, timeout=5.0)
                    if response.status_code == 200:
                        data = response.json()
                        fetched_models = [m["id"] for m in data.get("data", [])]
                        regex = re.compile(r"(text-davinci-003|gpt-|o\d+|chat-latest)")
                        exclude_regex = re.compile(r"audio|realtime")
                        filtered = [m for m in fetched_models if regex.search(m) and not exclude_regex.search(m)]
                        instruct_models = [m for m in filtered if "instruct" in m]
                        other_models = [m for m in filtered if "instruct" not in m]
                        if other_models or instruct_models:
                            fetched_list = other_models + instruct_models
                            combined = list(dict.fromkeys(models_dict["OpenAI"] + fetched_list))
                            models_dict["OpenAI"] = combined
            except Exception as e:  # noqa: BLE001
                logging.warning(f"Failed to fetch dynamic OpenAI models: {e}")  # noqa: LOG015
        _models_cache = models_dict
        _models_cache_time = time.time()
        return models_dict

    @app_router.get("/api/config/ui")
    async def get_ui_config():
        """Returns UI configuration URLs for the frontend."""
        config = get_config()
        return {"help_faq_url": config.help_faq_url, "terms_of_service_url": config.terms_of_service_url, "privacy_policy_url": config.privacy_policy_url}

    @app_router.get("/health")
    async def health_check():
        return {"status": "ok"}

    @app_router.get("/api/test-log")
    async def test_log():
        logger.warning("THIS IS A TEST LOG FROM API GATEWAY")
        return {"status": "logged"}
