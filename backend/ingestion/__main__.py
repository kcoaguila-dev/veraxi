import logging
from backend.config import get_config
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.ingestion.chunk_embed import chunk_and_embed
from backend.ingestion.extract import extract_entities_and_relations
from backend.ingestion.entity_resolution import resolve_entities
from backend.ingestion.graph_write import write_to_graph, IngestionPayload

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")


def run_ingestion(config, text: str, tenant_id: str = "default"):
    # 1. Initialize clients
    qdrant = QdrantStorageClient(url=config.qdrant_url, api_key=config.qdrant_api_key)
    neo4j = Neo4jStorageClient(
        uri=config.neo4j_uri, user=config.neo4j_user, password=config.neo4j_password
    )

    # Ensure qdrant collection exists
    COLLECTION_NAME = config.qdrant_collection_name
    qdrant.create_collection(COLLECTION_NAME)

    logging.info(f"Starting ingestion for tenant: {tenant_id}...")

    # 2. Chunk and embed
    chunks_and_embeddings = chunk_and_embed(text)

    vectors = [item[1] for item in chunks_and_embeddings]
    payloads = [{"text": item[0]} for item in chunks_and_embeddings]

    # 3. Write to Qdrant
    qdrant_point_ids_list = qdrant.insert_points(
        COLLECTION_NAME, vectors, payloads, tenant_id=tenant_id
    )
    logging.info(f"Inserted {len(qdrant_point_ids_list)} points into Qdrant.")

    # Create dict mapping to pass to graph step
    qdrant_point_ids = {
        f"chunk_{i}": pid for i, pid in enumerate(qdrant_point_ids_list)
    }

    # 4. Extract entities and relations
    entities, relations = extract_entities_and_relations(text)

    # Resolve entities to deduplicate and get alias mapping
    entities, alias_to_canonical = resolve_entities(entities)

    # Rewrite relation endpoints through alias mapping
    rewritten_relations = []
    for rel in relations:
        from_entity = alias_to_canonical.get(rel["from_entity"], rel["from_entity"])
        to_entity = alias_to_canonical.get(rel["to_entity"], rel["to_entity"])
        rewritten_relations.append({
            "from_entity": from_entity,
            "to_entity": to_entity,
            "type": rel["type"]
        })

    payload = IngestionPayload(
        entities=entities, relations=rewritten_relations, qdrant_point_ids=qdrant_point_ids
    )

    # 5. Write to Neo4j
    entity_id_map = write_to_graph(neo4j, payload, tenant_id=tenant_id)

    logging.info(
        f"Ingestion complete. {len(entity_id_map)} Neo4j nodes, {len(qdrant_point_ids)} Qdrant points, linking verified."
    )

    neo4j.close()

    return {
        "nodes_inserted": len(entity_id_map),
        "vectors_inserted": len(qdrant_point_ids),
    }


def main():
    config = get_config()
    text = (
        "Alice is a brilliant Engineer who works at Veraxi Corp. "
        "Veraxi Corp is an innovative Tech company that develops advanced AI. "
        "AI is transforming the Computer Science domain."
    )
    run_ingestion(config, text)


if __name__ == "__main__":
    main()
