import logging
import os
import sys

# Add backend directory to Python path if run from scripts folder
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.config import get_config
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

def wipe_databases():
    config = get_config()
    logger.warning("Initiating complete database wipe...")

    # Wipe Neo4j
    try:
        neo4j = Neo4jStorageClient.from_config(config)
        logger.info("Connected to Neo4j. Wiping graph data...")
        query = "MATCH (n) DETACH DELETE n"
        neo4j.execute_write(query)
        logger.info("Neo4j database successfully wiped.")
    except Exception as e:
        logger.error(f"Failed to wipe Neo4j: {e}")

    # Wipe Qdrant
    try:
        qdrant = QdrantStorageClient.from_config(config)
        logger.info(f"Connected to Qdrant. Recreating collection: {config.qdrant_collection_name}...")
        qdrant.client.delete_collection(collection_name=config.qdrant_collection_name)
        qdrant.create_collection(collection_name=config.qdrant_collection_name)
        logger.info("Qdrant collection successfully wiped and recreated.")
    except Exception as e:
        logger.error(f"Failed to wipe Qdrant: {e}")

    logger.info("Database wipe complete.")

if __name__ == "__main__":
    confirm = input("Are you sure you want to wipe Neo4j and Qdrant? This cannot be undone. (y/N): ")
    if confirm.lower() == 'y':
        wipe_databases()
    else:
        logger.info("Wipe aborted.")
