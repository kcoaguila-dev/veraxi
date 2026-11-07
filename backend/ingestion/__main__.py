from concurrent.futures import ThreadPoolExecutor
import hashlib
import logging
import threading
from typing import Any

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


def _tag_entities_with_chunk_provenance(
    entities: list[dict[str, Any]],
    chunk_items: list[tuple[str, str]],
) -> None:
    """Tags extracted entities with source_point_ids based on occurrence in chunks."""
    for ent in entities:
        if ent.get("source_point_ids"):
            continue
        ent_name = ent.get("name", "").strip().lower()
        if not ent_name:
            continue
        aliases = [
            str(a).strip().lower()
            for a in ent.get("aliases", [])
            if isinstance(a, str) and str(a).strip()
        ]
        search_terms = [ent_name] + aliases
        matched_pids = []
        for c_text, c_pid in chunk_items:
            c_text_lower = c_text.lower()
            if any(term in c_text_lower for term in search_terms):
                matched_pids.append(c_pid)
        if matched_pids:
            ent["source_point_ids"] = list(dict.fromkeys(matched_pids))


def run_ingestion(
    config,
    text: str,
    schema: dict,
    tenant_id: str = "default",
    fast_extraction: bool = False,
    language: str = "en",
    custom_stop_words: list | None = None,
    model: str | None = None,
    chunk_size: int = 800,
    chunk_overlap: int = 150,
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

    # Map each chunk's actual text content to its Qdrant point ID (as pairs to prevent collision)
    chunk_point_pairs = [
        (item[0], pid)
        for item, pid in zip(cleaned_chunks_and_embeddings, qdrant_point_ids_list)
    ]
    qdrant_point_ids = dict(chunk_point_pairs)

    try:
        # 4. Extract entities and relations
        if fast_extraction:
            logging.info(  # noqa: LOG015
                f"Using Fast Extraction (spaCy NLP) for entity extraction (Lang: {language})."
            )
            entities, relations = extract_entities_and_relations_fast(
                text, schema, language, custom_stop_words or []
            )
            _tag_entities_with_chunk_provenance(entities, chunk_point_pairs)
        else:
            logging.info("Using Deep Extraction (LLM) for entity extraction.")  # noqa: LOG015
            if len(cleaned_chunks_and_embeddings) <= 1:
                entities, relations = extract_entities_and_relations(
                    text, schema, model_name=model
                )
                first_pid = next(iter(qdrant_point_ids_list), None)
                if first_pid:
                    for ent in entities:
                        ent.setdefault("source_point_ids", []).append(first_pid)
            else:
                entities = []
                relations = []

                def _extract_chunk(chunk_item: tuple[str, str | None]):
                    c_text, c_pid = chunk_item
                    with _LLM_EXTRACTION_SEMAPHORE:
                        c_ents, c_rels = extract_entities_and_relations(
                            c_text, schema, model_name=model
                        )
                        if c_pid:
                            for ent in c_ents:
                                ent.setdefault("source_point_ids", []).append(c_pid)
                        return c_ents, c_rels

                chunk_items = [
                    (item[0], pid)
                    for item, pid in zip(cleaned_chunks_and_embeddings, qdrant_point_ids_list)
                ]
                with ThreadPoolExecutor(max_workers=min(4, len(chunk_items))) as pool:
                    for chunk_ents, chunk_rels in pool.map(_extract_chunk, chunk_items):
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
            qdrant_point_ids=chunk_point_pairs,
            source=source,
        )

        # 5. Write to Neo4j
        entity_id_map, qdrant_id_to_neo4j_ids, qdrant_id_to_entity_names = write_to_graph(
            neo4j, payload, tenant_id=tenant_id
        )

        # 6. Critical Link: Update Qdrant points with their corresponding Neo4j Node IDs and entity names
        # Retrieve existing payloads for these points to merge non-destructively
        existing_points = qdrant.get_points(COLLECTION_NAME, list(qdrant_id_to_neo4j_ids.keys()))
        existing_payloads = {p["id"]: p.get("payload", {}) for p in existing_points if isinstance(p, dict) and "id" in p}

        updates_by_point_id: dict[str, dict] = {}
        for q_id, n_ids in qdrant_id_to_neo4j_ids.items():
            curr_payload = existing_payloads.get(q_id, {})
            merged_n_ids = list(dict.fromkeys(curr_payload.get("neo4j_node_ids", []) + n_ids))
            new_names = qdrant_id_to_entity_names.get(q_id, [])
            merged_names = list(dict.fromkeys(curr_payload.get("entity_names", []) + new_names))

            update_payload: dict = {"neo4j_node_ids": merged_n_ids}
            if merged_names:
                update_payload["entity_names"] = merged_names
                update_payload["entity_name"] = merged_names[0]
            updates_by_point_id[q_id] = update_payload

        qdrant.batch_set_payloads(
            collection_name=COLLECTION_NAME,
            payload_by_point_id=updates_by_point_id,
        )
    except Exception as exc:
        import sentry_sdk
        sentry_sdk.capture_exception(exc)
        logging.error(
            f"Ingestion failed after inserting points into Qdrant. Executing compensating rollback: {exc}"
        )
        try:
            qdrant.delete_points(COLLECTION_NAME, qdrant_point_ids_list)
        except Exception as rb_exc:
            sentry_sdk.capture_exception(rb_exc)
            logging.error(f"Compensating rollback of Qdrant points failed: {rb_exc}")
        neo4j.close()
        raise

    logging.info(  # noqa: LOG015
        f"Ingestion complete. {len(entity_id_map)} Neo4j nodes, {len(qdrant_point_ids_list)} Qdrant points, linking verified."
    )

    neo4j.close()

    return {
        "nodes_inserted": len(entity_id_map),
        "vectors_inserted": len(qdrant_point_ids_list),
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
