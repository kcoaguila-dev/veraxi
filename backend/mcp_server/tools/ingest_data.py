from typing import Dict, Any
import logging
from backend.config import get_config
from backend.ingestion.__main__ import run_ingestion

logger = logging.getLogger(__name__)

def ingest_data(text: str, tenant_id: str = "default") -> str:
    """
    Ingest text data into the Veraxi knowledge graph and vector store.
    This runs the full Docling/Neo4j GraphRAG ingestion pipeline.
    """
    try:
        config = get_config()
        result = run_ingestion(config, text, tenant_id=tenant_id)
        nodes = result.get("nodes_inserted", 0)
        vectors = result.get("vectors_inserted", 0)
        return f"Successfully ingested data. Inserted {nodes} graph nodes and {vectors} vector embeddings."
    except Exception as e:
        logger.error(f"Error in ingest_data tool: {e}")
        return f"Error executing ingestion tool: {e}"
