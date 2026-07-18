# backend/config.py
import os
from dataclasses import dataclass
from functools import lru_cache
from typing import Optional
from dotenv import load_dotenv

load_dotenv()


@dataclass
class Config:
    neo4j_uri: str
    neo4j_user: str
    neo4j_password: str
    qdrant_url: str
    qdrant_api_key: Optional[str]
    qdrant_collection_name: str
    llm_api_key: str
    llm_base_url: str
    llm_model_name: str
    embedding_api_key: str
    embedding_model_name: str
    sentry_dsn: str
    stripe_api_key: str
    stripe_webhook_secret: str
    supabase_url: str
    supabase_service_key: str
    rate_limit_chat: str
    rate_limit_ingest: str
    rate_limit_sse: str
    default_search_limit: int
    default_max_hops: int

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            neo4j_uri=_require("NEO4J_URI"),
            neo4j_user=_require("NEO4J_USER"),
            neo4j_password=_require("NEO4J_PASSWORD"),
            qdrant_url=_require("QDRANT_URL"),
            qdrant_api_key=os.environ.get("QDRANT_API_KEY"),
            qdrant_collection_name=os.environ.get("QDRANT_COLLECTION_NAME", "veraxi_docs"),
            llm_api_key=os.environ.get("LLM_API_KEY", ""),
            llm_base_url=os.environ.get("LLM_BASE_URL", ""),
            llm_model_name=os.environ.get("LLM_MODEL_NAME", "gemini-2.5-flash"),
            embedding_api_key=os.environ.get("EMBEDDING_API_KEY", ""),
            embedding_model_name=os.environ.get(
                "EMBEDDING_MODEL_NAME", "text-embedding-004"
            ),
            sentry_dsn=os.environ.get("SENTRY_DSN", ""),
            stripe_api_key=os.environ.get("STRIPE_API_KEY", ""),
            stripe_webhook_secret=os.environ.get("STRIPE_WEBHOOK_SECRET", ""),
            supabase_url=os.environ.get("SUPABASE_URL", ""),
            supabase_service_key=os.environ.get("SUPABASE_SERVICE_KEY", ""),
            rate_limit_chat=os.environ.get("RATE_LIMIT_CHAT", "100/day"),
            rate_limit_ingest=os.environ.get("RATE_LIMIT_INGEST", "50/day"),
            rate_limit_sse=os.environ.get("RATE_LIMIT_SSE", "10/minute"),
            default_search_limit=int(os.environ.get("DEFAULT_SEARCH_LIMIT", "10")),
            default_max_hops=int(os.environ.get("DEFAULT_MAX_HOPS", "2")),
        )

def _require(key: str) -> str:
    value = os.environ.get(key)
    if not value:
        raise RuntimeError(
            f"Missing required environment variable: {key}. "
            f"Check your .env file against .env.example."
        )
    return value


@lru_cache
def get_config() -> Config:
    """Load and cache Config from environment. Call this where config is
    actually needed (e.g. storage client init) — never at import time."""
    return Config.from_env()
