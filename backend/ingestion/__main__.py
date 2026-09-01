import logging

from backend.config import get_config
from backend.ingestion.chunk_embed import chunk_and_embed
from backend.ingestion.entity_resolution import resolve_entities
from backend.ingestion.extract import (
    extract_entities_and_relations,
    extract_entities_and_relations_fast,
)
from backend.ingestion.graph_write import IngestionPayload, write_to_graph
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")


def run_ingestion(config, text: str, schema: dict, tenant_id: str = "default", fast_extraction: bool = False, language: str = "en", custom_stop_words: list | None = None, model: str | None = None):
    # 1. Initialize clients
    qdrant = QdrantStorageClient.from_config(config)
    neo4j = Neo4jStorageClient.from_config(config)

    # Ensure qdrant collection exists
    COLLECTION_NAME = config.qdrant_collection_name
    qdrant.create_collection(COLLECTION_NAME)

    logging.info(f"Starting ingestion for tenant: {tenant_id}...")  # noqa: LOG015

    # 2. Chunk and embed
    chunks_and_embeddings = chunk_and_embed(text)

    vectors = [item[1] for item in chunks_and_embeddings]
    sparse_vectors = [item[2] for item in chunks_and_embeddings]
    payloads = [{"text": item[0]} for item in chunks_and_embeddings]

    # 3. Write to Qdrant
    qdrant_point_ids_list = qdrant.insert_points(
        COLLECTION_NAME, vectors, sparse_vectors, payloads, tenant_id=tenant_id
    )
    logging.info(f"Inserted {len(qdrant_point_ids_list)} points into Qdrant.")  # noqa: LOG015

    # Create dict mapping to pass to graph step
    qdrant_point_ids = {
        f"chunk_{i}": pid for i, pid in enumerate(qdrant_point_ids_list)
    }

    # 4. Extract entities and relations
    if fast_extraction:
        logging.info(f"Using Fast Extraction (spaCy NLP) for entity extraction (Lang: {language}).")  # noqa: LOG015
        entities, relations = extract_entities_and_relations_fast(text, schema, language, custom_stop_words or [])
    else:
        logging.info("Using Deep Extraction (LLM) for entity extraction.")  # noqa: LOG015
        entities, relations = extract_entities_and_relations(text, schema, model_name=model)

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
    entity_id_map, qdrant_id_to_neo4j_ids = write_to_graph(neo4j, payload, tenant_id=tenant_id)
    
    # 6. Critical Link: Update Qdrant points with their corresponding Neo4j Node IDs
    for q_id, n_ids in qdrant_id_to_neo4j_ids.items():
        qdrant.client.set_payload(
            collection_name=COLLECTION_NAME,
            payload={"neo4j_node_ids": n_ids},
            points=[q_id],
        )

    logging.info(  # noqa: LOG015
        f"Ingestion complete. {len(entity_id_map)} Neo4j nodes, {len(qdrant_point_ids)} Qdrant points, linking verified."
    )

    neo4j.close()

    return {
        "nodes_inserted": len(entity_id_map),
        "vectors_inserted": len(qdrant_point_ids),
    }


def main():
    config = get_config()
    import os
    
    # ⚠️ ARCHITECTURE NOTE FOR PRODUCTION ⚠️
    # The current 'graphrag_test_corpus.txt' is a tiny 300-word file meant ONLY for fast CI/CD pipeline checks. 
    # To properly test RAG (Reciprocal Rank Fusion, Context Precision/Recall), you must replace this file 
    # with a massive, unstructured text corpus (e.g., the 'Paul Graham Essays' dataset or a 50-page PDF).
    # You must also inject a "Needle In A Haystack" fact into that corpus and update `dataset.json` to query it.
    
    corpus_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "tests", "data", "graphrag_test_corpus.txt")
    with open(corpus_path, "r", encoding="utf-8") as f:
        text = f.read()
        
    # For local CLI testing, we mock a schema since it is now strictly required.
    mock_schema = {
        "entities": ["Person", "Organization", "Location"],
        "relations": {"Person": {"Organization": ["WORKS_AT"]}}
    }
    run_ingestion(config, text, schema=mock_schema)


if __name__ == "__main__":
    main()
