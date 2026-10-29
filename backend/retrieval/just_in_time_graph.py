"""
Just-In-Time (Lazy) GraphRAG Module for Veraxi.

Enables zero-cloud-cost, on-demand graph construction directly from
ground-truth Qdrant text chunks:
  1. Retrieve high-precision passages via Qdrant Hybrid Search (Dense MiniLM + Sparse SPLADE).
  2. Identify existing entity anchors in Neo4j linked to those passages.
  3. Compile a Video Research Dossier with grounded citations.
  4. Allow Host AI (Antigravity / Claude Code) to commit rich causal triples into Neo4j.
"""

from __future__ import annotations

import logging
from typing import Any

from backend.config import get_config
from backend.ingestion.chunk_embed import embed_text, embed_text_sparse
from backend.storage.graph_operations import (
    insert_graph_nodes,
    purge_cooccurrence_relationships,
)
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient

logger = logging.getLogger(__name__)


def build_lazy_graph_dossier(
    query: str,
    tenant_id: str = "default",
    limit: int = 15,
) -> dict[str, Any]:
    """
    Extracts high-precision context for an analytical research topic or query.
    Fuses hybrid vector search with Neo4j entity anchors to compile a structured dossier.
    """
    config = get_config()
    qdrant = QdrantStorageClient.from_config(config)
    neo4j = Neo4jStorageClient.from_config(config)

    # 1. Embed query (dense MiniLM + sparse SPLADE)
    dense_vec = embed_text(query)
    sparse_vec = embed_text_sparse(query)

    # 2. Hybrid search in Qdrant
    hits = qdrant.search_hybrid(
        collection_name=config.qdrant_collection_name,
        query_vector=dense_vec,
        sparse_query_vector=sparse_vec,
        limit=limit,
        tenant_id=tenant_id,
    )

    chunks = []
    chunk_ids = []
    for hit in hits:
        cid = str(hit.get("id"))
        chunk_ids.append(cid)
        payload = hit.get("payload", {})
        chunks.append(
            {
                "point_id": cid,
                "score": float(hit.get("score", 0.0)),
                "text": payload.get("text", ""),
                "title": payload.get("title")
                or payload.get("document_id")
                or "Document",
                "metadata": payload.get("metadata", {}),
            }
        )

    # 3. Pull linked entity anchors from Neo4j
    entities_by_chunk: dict[str, list[dict[str, Any]]] = {}
    if chunk_ids:
        cypher = """
        MATCH (n)
        WHERE n.tenant_id = $tenant_id AND n.qdrant_point_id IN $chunk_ids
        RETURN n.name AS name, labels(n)[0] AS type, n.qdrant_point_id AS q_id
        """
        try:
            records = neo4j.execute_read(
                cypher, {"tenant_id": tenant_id, "chunk_ids": chunk_ids}
            )
            for r in records:
                qid = r.get("q_id")
                if qid not in entities_by_chunk:
                    entities_by_chunk[qid] = []
                entities_by_chunk[qid].append(
                    {"name": r.get("name"), "type": r.get("type")}
                )
        except Exception as e:
            logger.warning(f"Error querying Neo4j entity anchors: {e}")
        finally:
            neo4j.close()

    # 4. Attach entity anchors to chunks
    for ch in chunks:
        ch["linked_entities"] = entities_by_chunk.get(ch["point_id"], [])

    # 5. Format prompt template for Host AI (Subscription agent)
    host_ai_prompt = (
        f"You are an expert analytical researcher. Below are {len(chunks)} ground-truth "
        f"evidence excerpts retrieved from our indexed knowledge base for the query: '{query}'.\n\n"
        "TASK:\n"
        "1. Build a strict chronological timeline of events, causal developments, and key findings.\n"
        "2. Formulate high-precision CAUSAL triples to commit to our Knowledge Graph in JSON format:\n"
        "   {\n"
        '     "nodes": [{"type": "Entity|Organization|Person|Concept", "name": "...", "properties": {...}}],\n'
        '     "relations": [{"from_entity": "...", "to_entity": "...", "type": "CAUSAL_RELATION", "properties": {"method": "...", "date": "..."}}]\n'
        "   }\n"
        "3. Synthesize the core findings citing the source quotes and document titles provided."
    )

    return {
        "query": query,
        "tenant_id": tenant_id,
        "total_chunks_retrieved": len(chunks),
        "chunks": chunks,
        "host_ai_instruction": host_ai_prompt,
    }


def commit_causal_graph(
    nodes: list[dict[str, Any]],
    relations: list[dict[str, Any]],
    tenant_id: str = "default",
) -> dict[str, Any]:
    """
    Commits vetted causal graph nodes and relationships extracted by Host AI into Neo4j.
    """
    return insert_graph_nodes(nodes=nodes, relations=relations, tenant_id=tenant_id)


def purge_noisy_relationships(tenant_id: str = "default") -> dict[str, Any]:
    """
    Cleanses the Neo4j graph of sentence co-occurrence noise for the tenant.
    """
    return purge_cooccurrence_relationships(tenant_id=tenant_id)
