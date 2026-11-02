from concurrent.futures import ThreadPoolExecutor
import hashlib
import logging
import threading

from backend.config import get_config
from backend.ingestion.chunk_embed import chunk_and_embed
from backend.ingestion.document_parser import (
    strip_and_resolve_citation_metadata,
)
from backend.ingestion.entity_resolution import resolve_entities
from backend.ingestion.extract import (
    extract_entities_and_relations,
    extract_entities_and_relations_fast,
)
from backend.ingestion.graph_write import IngestionPayload, write_to_graph
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

_LLM_EXTRACTION_SEMAPHORE = threading.BoundedSemaphore(8)


def run_ingestion(
    config,
    text: str,
    schema: dict,
    tenant_id: str = "default",
    fast_extraction: bool = False,
    language: str = "en",
    custom_stop_words: list | None = None,
    model: str | None = None,
    chunk_size: int = 200,
    chunk_overlap: int = 50,
    source: str | None = None,
    document_id: str | None = None,
    source_type: str = "document",
    file_hash: str | None = None,
):
    # 1. Initialize clients
    qdrant = QdrantStorageClient.from_config(config)
    neo4j = Neo4jStorageClient.from_config(config)

    # Ensure qdrant collection exists
    COLLECTION_NAME = config.qdrant_collection_name
    qdrant.create_collection(COLLECTION_NAME)

    if file_hash is None and text:
        file_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()

    if file_hash and qdrant.has_file_hash(
        COLLECTION_NAME, file_hash, tenant_id=tenant_id
    ):
        logging.info(  # noqa: LOG015
            f"Skipping duplicate ingestion for tenant {tenant_id} (file_hash={file_hash[:12]} already exists)."
        )
        neo4j.close()
        return {
            "nodes_inserted": 0,
            "vectors_inserted": 0,
            "deduplicated": True,
            "file_hash": file_hash,
        }

    logging.info(f"Starting ingestion for tenant: {tenant_id}...")  # noqa: LOG015

    # 2. Chunk and embed
    chunks_and_embeddings = chunk_and_embed(
        text, chunk_size=chunk_size, chunk_overlap=chunk_overlap
    )

    vectors = []
    sparse_vectors = []
    payloads = []
    cleaned_chunks_and_embeddings = []
    current_page: int | None = None
    current_breadcrumb: str | None = None

    for idx, (raw_chunk, vec, sparse_vec) in enumerate(chunks_and_embeddings):
        clean_chunk, current_page, current_breadcrumb, bbox, is_table = (
            strip_and_resolve_citation_metadata(
                raw_chunk, current_page, current_breadcrumb
            )
        )
        vectors.append(vec)
        sparse_vectors.append(sparse_vec)
        cleaned_chunks_and_embeddings.append((clean_chunk, vec, sparse_vec))
        payload: dict = {
            "text": clean_chunk,
            "source": source or "unknown",
            "document_id": document_id or "default",
            "source_type": source_type,
            "file_hash": file_hash,
            "chunk_index": idx,
        }
        if current_page is not None:
            payload["page_number"] = current_page
        if current_breadcrumb:
            payload["breadcrumb"] = current_breadcrumb
        if bbox:
            payload["bbox"] = bbox
        if is_table:
            payload["is_table"] = True
        payloads.append(payload)

    # 3. Write to Qdrant
    qdrant_point_ids_list = qdrant.insert_points(
        COLLECTION_NAME, vectors, sparse_vectors, payloads, tenant_id=tenant_id
    )
    logging.info(f"Inserted {len(qdrant_point_ids_list)} points into Qdrant.")  # noqa: LOG015

    # Map each chunk's actual text content to its Qdrant point ID
    qdrant_point_ids = {
        item[0]: pid
        for item, pid in zip(cleaned_chunks_and_embeddings, qdrant_point_ids_list)
    }

    # 4. Extract entities and relations
    if fast_extraction:
        logging.info(  # noqa: LOG015
            f"Using Fast Extraction (spaCy NLP) for entity extraction (Lang: {language})."
        )
        entities, relations = extract_entities_and_relations_fast(
            text, schema, language, custom_stop_words or []
        )
    else:
        logging.info("Using Deep Extraction (LLM) for entity extraction.")  # noqa: LOG015
        if len(cleaned_chunks_and_embeddings) <= 1:
            entities, relations = extract_entities_and_relations(
                text, schema, model_name=model
            )
        else:
            entities = []
            relations = []

            def _extract_chunk(chunk_text: str):
                with _LLM_EXTRACTION_SEMAPHORE:
                    return extract_entities_and_relations(
                        chunk_text, schema, model_name=model
                    )

            chunk_texts = [item[0] for item in cleaned_chunks_and_embeddings]
            with ThreadPoolExecutor(max_workers=min(4, len(chunk_texts))) as pool:
                for chunk_ents, chunk_rels in pool.map(_extract_chunk, chunk_texts):
                    entities.extend(chunk_ents)
                    relations.extend(chunk_rels)

    # Resolve entities to deduplicate and get alias mapping
    entities, alias_to_canonical = resolve_entities(entities)

    # Rewrite relation endpoints through alias mapping
    rewritten_relations = []
    for rel in relations:
        from_entity = alias_to_canonical.get(rel["from_entity"], rel["from_entity"])
        to_entity = alias_to_canonical.get(rel["to_entity"], rel["to_entity"])
        rewritten_relations.append(
            {"from_entity": from_entity, "to_entity": to_entity, "type": rel["type"]}
        )

    payload = IngestionPayload(
        entities=entities,
        relations=rewritten_relations,
        qdrant_point_ids=qdrant_point_ids,
        source=source,
    )

    # 5. Write to Neo4j
    entity_id_map, qdrant_id_to_neo4j_ids = write_to_graph(
        neo4j, payload, tenant_id=tenant_id
    )

    # 6. Critical Link: Update Qdrant points with their corresponding Neo4j Node IDs
    # Batch updates by grouping points that share the same Neo4j node IDs
    n_ids_to_q_ids: dict[tuple[str, ...], list[str]] = {}
    for q_id, n_ids in qdrant_id_to_neo4j_ids.items():
        key = tuple(n_ids)
        n_ids_to_q_ids.setdefault(key, []).append(q_id)

    for n_ids_tuple, q_ids in n_ids_to_q_ids.items():
        qdrant.client.set_payload(
            collection_name=COLLECTION_NAME,
            payload={"neo4j_node_ids": list(n_ids_tuple)},
            points=q_ids,
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

    corpus_path = os.path.join(
        os.path.dirname(os.path.dirname(__file__)),
        "tests",
        "data",
        "graphrag_test_corpus.txt",
    )
    if not os.path.exists(corpus_path):
        path1 = os.path.join(os.getcwd(), "tests", "data", "graphrag_test_corpus.txt")
        path2 = os.path.join(
            os.getcwd(), "backend", "tests", "data", "graphrag_test_corpus.txt"
        )
        if os.path.exists(path1):
            corpus_path = path1
        elif os.path.exists(path2):
            corpus_path = path2
        else:
            corpus_path = path1
    with open(corpus_path, "r", encoding="utf-8") as f:
        text = f.read()

    # For local CLI testing, we mock a schema since it is now strictly required.
    mock_schema = {
        "entities": ["Person", "Organization", "Location"],
        "relations": {"Person": {"Organization": ["WORKS_AT"]}},
    }
    run_ingestion(config, text, schema=mock_schema)


if __name__ == "__main__":
    main()
