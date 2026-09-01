from contextvars import ContextVar

# Context variables for BYOD Database credentials injected per-request via headers
request_neo4j_uri: ContextVar[str | None] = ContextVar("request_neo4j_uri", default=None)
request_neo4j_user: ContextVar[str | None] = ContextVar("request_neo4j_user", default=None)
request_neo4j_pass: ContextVar[str | None] = ContextVar("request_neo4j_pass", default=None)
request_qdrant_url: ContextVar[str | None] = ContextVar("request_qdrant_url", default=None)
request_qdrant_key: ContextVar[str | None] = ContextVar("request_qdrant_key", default=None)
