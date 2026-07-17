import contextvars

# Global context variable to store the tenant_id for the current HTTP/SSE request
tenant_context = contextvars.ContextVar("tenant_id", default="default")
