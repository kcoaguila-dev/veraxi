import contextvars
import os

# Global context variable to store the tenant_id for the current HTTP/SSE request
tenant_context = contextvars.ContextVar(
    "tenant_id",
    default=os.environ.get("DEFAULT_TENANT_ID", os.environ.get("TENANT_ID", "default")),
)

