import logging
from backend.config import get_config
from backend.ingestion.__main__ import run_ingestion

logger = logging.getLogger(__name__)


def ingest_data(text: str, tenant_id: str = "default") -> str:
    """
    Ingests text data by extracting entities and relations and saving them to the databases.
    """
    try:
        config = get_config()
        result = run_ingestion(config, text, tenant_id=tenant_id)

        nodes_inserted = result.get("nodes_inserted", 0)
        vectors_inserted = result.get("vectors_inserted", 0)

        return f"Successfully ingested data. Inserted {nodes_inserted} graph nodes and {vectors_inserted} vector embeddings."
    except Exception as e:
        logger.error(f"Error executing ingestion tool: {e}")
        return f"Error executing ingestion tool: {e}"
