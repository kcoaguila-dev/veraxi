from contextvars import ContextVar
from typing import Optional

# Context variables for BYOD Database credentials injected per-request via headers
request_neo4j_uri: ContextVar[Optional[str]] = ContextVar("request_neo4j_uri", default=None)
request_neo4j_user: ContextVar[Optional[str]] = ContextVar("request_neo4j_user", default=None)
request_neo4j_pass: ContextVar[Optional[str]] = ContextVar("request_neo4j_pass", default=None)
request_qdrant_url: ContextVar[Optional[str]] = ContextVar("request_qdrant_url", default=None)
request_qdrant_key: ContextVar[Optional[str]] = ContextVar("request_qdrant_key", default=None)
