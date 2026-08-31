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
    postgres_url: str
    rate_limit_chat: str
    rate_limit_ingest: str
    rate_limit_sse: str
    default_search_limit: int
    default_max_hops: int
    searxng_url: str
    redis_url: str
    auth_enabled: bool
    cors_origins: str
    gpt_sovits_base_url: str
    code_interpreter_url: str
    is_enterprise: bool
    help_faq_url: str
    terms_of_service_url: str
    privacy_policy_url: str
    max_tenant_nodes: int

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
            llm_model_name=os.environ.get("LLM_MODEL_NAME", ""),
            embedding_api_key=os.environ.get("EMBEDDING_API_KEY", ""),
            embedding_model_name=os.environ.get(
                "EMBEDDING_MODEL_NAME", "text-embedding-004"
            ),
            sentry_dsn=os.environ.get("SENTRY_DSN", ""),
            stripe_api_key=os.environ.get("STRIPE_SECRET_KEY", os.environ.get("STRIPE_API_KEY", "")),
            stripe_webhook_secret=os.environ.get("STRIPE_WEBHOOK_SECRET", ""),
            supabase_url=os.environ.get("SUPABASE_URL", ""),
            supabase_service_key=os.environ.get("SUPABASE_SERVICE_KEY", ""),
            postgres_url=os.environ.get("POSTGRES_URL", "postgresql://postgres:postgres@localhost:5432/postgres"),
            rate_limit_chat=os.environ.get("RATE_LIMIT_CHAT", "100/day"),
            rate_limit_ingest=os.environ.get("RATE_LIMIT_INGEST", "50/day"),
            rate_limit_sse=os.environ.get("RATE_LIMIT_SSE", "10/minute"),
            default_search_limit=int(os.environ.get("DEFAULT_SEARCH_LIMIT", "10")),
            default_max_hops=int(os.environ.get("DEFAULT_MAX_HOPS", "2")),
            searxng_url=os.environ.get("SEARXNG_BASE_URL", "http://searxng:8080/"),
            redis_url=os.environ.get("REDIS_URL", "redis://localhost:6379/0"),
            auth_enabled=os.environ.get("AUTH_ENABLED", "true").lower() == "true",
            max_tenant_nodes=int(os.environ.get("MAX_TENANT_NODES", "1000")),
            cors_origins=os.environ.get("CORS_ORIGINS", "*"),
            gpt_sovits_base_url=os.environ.get("GPT_SOVITS_BASE_URL", "http://localhost:9880"),
            code_interpreter_url=os.environ.get("CODE_INTERPRETER_URL", "http://code_interpreter:8000/execute"),
            is_enterprise=os.environ.get("IS_ENTERPRISE", "false").lower() == "true",
            help_faq_url=os.environ.get("HELP_FAQ_URL", "https://veraxi.ai/help"),
            terms_of_service_url=os.environ.get("TERMS_OF_SERVICE_URL", "https://veraxi.ai/terms"),
            privacy_policy_url=os.environ.get("PRIVACY_POLICY_URL", "https://veraxi.ai/privacy"),
        )

    def get_llm_client_args(self, model_name: Optional[str] = None) -> dict:
        """Returns kwargs for initializing OpenAI-compatible clients."""
        args = {}
        if self.llm_api_key:
            args["api_key"] = self.llm_api_key
        if self.llm_base_url:
            args["base_url"] = self.llm_base_url
        else:
            effective_model = model_name or self.llm_model_name
            if effective_model.startswith("gemini"):
                args["base_url"] = "https://generativelanguage.googleapis.com/v1beta/openai/"
            elif effective_model.startswith("gpt") or effective_model.startswith("o1") or effective_model.startswith("o3"):
                pass  # Default to api.openai.com
            elif effective_model.startswith("deepseek"):
                args["base_url"] = "https://api.deepseek.com"
            elif effective_model.startswith("moonshot"):
                args["base_url"] = "https://api.moonshot.cn/v1"
            elif effective_model.startswith("mistral"):
                args["base_url"] = "https://api.mistral.ai/v1"
            elif not effective_model.startswith("claude"):
                # Fallback to groq for llama, mixtral, qwen, etc.
                args["base_url"] = "https://api.groq.com/openai/v1"
        return args

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
