import contextvars
import os

_DEFAULT_TENANT = str(os.environ.get("DEFAULT_TENANT_ID", os.environ.get("TENANT_ID", "default")))

# Global context variable to store the tenant_id for the current HTTP/SSE request
tenant_context: contextvars.ContextVar[str] = contextvars.ContextVar(
    "tenant_id",
    default=_DEFAULT_TENANT,
)

