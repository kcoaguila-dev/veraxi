import logging
import sys
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.ingestion.chunk_embed import chunk_and_embed
from backend.ingestion.extract import extract_entities_and_relations
from backend.ingestion.entity_resolution import resolve_entities
from backend.ingestion.graph_write import write_to_graph

logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

def run_ingestion(config):
    # 1. Initialize clients
    qdrant = QdrantStorageClient(url=config.qdrant_url, api_key=config.qdrant_api_key)
    neo4j = Neo4jStorageClient(uri=config.neo4j_uri, user=config.neo4j_user, password=config.neo4j_password)

    # Ensure qdrant collection exists
    COLLECTION_NAME = "veraxi_docs"
    qdrant.create_collection(COLLECTION_NAME)

    # Hardcoded test text
    text = (
        "Alice is a brilliant Engineer who works at Veraxi Corp. "
        "Veraxi Corp is an innovative Tech company that develops advanced AI. "
        "AI is transforming the Computer Science domain."
    )

    logging.info("Starting ingestion...")

    # 2. Chunk and embed
    chunks_and_embeddings = chunk_and_embed(text)

    vectors = [item[1] for item in chunks_and_embeddings]
    payloads = [{"text": item[0]} for item in chunks_and_embeddings]

    # 3. Write to Qdrant
    qdrant_point_ids_list = qdrant.insert_points(COLLECTION_NAME, vectors, payloads)
    logging.info(f"Inserted {len(qdrant_point_ids_list)} points into Qdrant.")

    # Create dict mapping to pass to graph step
    qdrant_point_ids = {f"chunk_{i}": pid for i, pid in enumerate(qdrant_point_ids_list)}

    # 4. Extract entities and relations
    entities, relations = extract_entities_and_relations(text)

    # Resolve entities to deduplicate
    entities = resolve_entities(entities)

    # 5. Write to Neo4j
    entity_id_map = write_to_graph(neo4j, entities, relations, qdrant_point_ids)

    logging.info(f"Ingestion complete. {len(entity_id_map)} Neo4j nodes, {len(qdrant_point_ids)} Qdrant points, linking verified.")

    neo4j.close()

    return {
        "nodes_inserted": len(entity_id_map),
        "vectors_inserted": len(qdrant_point_ids)
    }

def main():
    config = get_config()
    run_ingestion(config)

if __name__ == "__main__":
    main()
