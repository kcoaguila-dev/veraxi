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

        # Require both counters to be present - incomplete result is an error
        if "nodes_inserted" not in result or "vectors_inserted" not in result:
            logger.error(f"Incomplete ingestion result: {result}")
            return "Error executing ingestion tool: Incomplete result from ingestion pipeline."

        nodes_inserted = result["nodes_inserted"]
        vectors_inserted = result["vectors_inserted"]

        return f"Successfully ingested data. Inserted {nodes_inserted} graph nodes and {vectors_inserted} vector embeddings."
    except Exception as e:
        logger.error(f"Error executing ingestion tool: {e}", exc_info=True)
        return "Error executing ingestion tool: An unexpected error occurred during ingestion."
