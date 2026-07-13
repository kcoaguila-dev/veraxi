# backend/config.py
import os
from dataclasses import dataclass
from functools import lru_cache


@dataclass
class Config:
    neo4j_uri: str
    neo4j_user: str
    neo4j_password: str
    qdrant_url: str
    qdrant_api_key: str
    gemini_api_key: str
    embedding_api_key: str

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            neo4j_uri=_require("NEO4J_URI"),
            neo4j_user=_require("NEO4J_USER"),
            neo4j_password=_require("NEO4J_PASSWORD"),
            qdrant_url=_require("QDRANT_URL"),
            qdrant_api_key=os.environ.get("QDRANT_API_KEY", ""),
            gemini_api_key=_require("GEMINI_API_KEY"),
            embedding_api_key=os.environ.get("EMBEDDING_API_KEY", ""),
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