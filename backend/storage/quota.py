"""
backend/storage/quota.py

Tenant quota enforcement — shared by both the API gateway and the MCP server.

This is the single authoritative location for the free-tier hard cap check.
Both entry points (REST ingestion and MCP insert tools) must call this before
writing data so that cloud users cannot bypass limits regardless of how they
connect.

Self-hosted deployments (AUTH_ENABLED=false) never reach this check because
get_tenant_id() returns "local_personal_user" and callers skip the check
when auth is disabled — matching the behaviour of rivals like LibreChat.
"""
import logging

import sentry_sdk
from fastapi import HTTPException

from backend.config import Config, get_config
from backend.storage.neo4j_client import Neo4jStorageClient

logger = logging.getLogger(__name__)


def check_tenant_hard_cap(
    tenant_id: str,
    config: Config | None = None,
) -> None:
    """Raise HTTP 403 if the tenant has reached their node quota.

    Args:
        tenant_id: The tenant whose nodes are counted.
        config:    Optional pre-loaded Config; fetched from cache if omitted.

    Raises:
        HTTPException(403): When the tenant is at or above ``max_tenant_nodes``.
    """
    if config is None:
        config = get_config()

    _enforce_cap(tenant_id, config)


# ---------------------------------------------------------------------------
# Private helpers — keep the public surface minimal
# ---------------------------------------------------------------------------

def _count_tenant_nodes(tenant_id: str, config: Config) -> int:
    """Return the number of Neo4j nodes belonging to this tenant."""
    neo4j = Neo4jStorageClient.from_config(config)
    try:
        records = neo4j.execute_read(
            "MATCH (n) WHERE n.tenant_id = $tenant_id RETURN count(n) AS count",
            parameters={"tenant_id": tenant_id},
        )
        return records[0]["count"] if records else 0
    finally:
        neo4j.close()


def _enforce_cap(tenant_id: str, config: Config) -> None:
    """Query the node count and raise if the cap is reached."""
    try:
        node_count = _count_tenant_nodes(tenant_id, config)
        if node_count >= config.max_tenant_nodes:
            raise HTTPException(
                status_code=403,
                detail=(
                    f"You have reached your personal Free Tier quota of "
                    f"{config.max_tenant_nodes} knowledge nodes. Please delete "
                    f"some older documents to free up space, or upgrade to Premium."
                ),
            )
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Failed to check hard cap for tenant {tenant_id}: {e}")
