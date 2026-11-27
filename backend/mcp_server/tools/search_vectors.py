from concurrent.futures import ThreadPoolExecutor
import logging
import sentry_sdk

from backend.config import get_config
from backend.ingestion.chunk_embed import embed_code_text, embed_text, embed_text_sparse
from backend.retrieval.merge_rank import VectorHit
from backend.storage.qdrant_client import QdrantStorageClient
from backend.storage.scope import scope_filter_values

logger = logging.getLogger(__name__)

_EMBED_EXECUTOR = ThreadPoolExecutor(
    max_workers=4, thread_name_prefix="veraxi-query-embed"
)


def _search_collection(
    qdrant_client: QdrantStorageClient,
    collection_name: str,
    query_text: str,
    dense_fn,
    sparse_query_vector,
    limit: int,
    tenant_id: str,
    source_scope: dict | None,
) -> list[VectorHit]:
    future_dense = _EMBED_EXECUTOR.submit(dense_fn, query_text)
    query_vector = future_dense.result()
    results = qdrant_client.search_hybrid(
        collection_name=collection_name,
        query_vector=query_vector,
        sparse_query_vector=sparse_query_vector,
        limit=limit,
        tenant_id=tenant_id,
        source_scope=source_scope,
    )
    return [
        VectorHit(id=hit["id"], score=hit["score"], payload=hit["payload"])
        for hit in results
    ]


def search_vectors(
    query_text: str,
    limit: int = 10,
    tenant_id: str = "default",
    source_scope: dict | None = None,
) -> list[VectorHit]:
    """
    Search Qdrant vectors using Hybrid Search (Dense + Sparse).
    Embeds the query_text, performs a hybrid search, and returns VectorHit objects ready for merge_rank.
    ``source_scope`` (Code Mode) narrows the tenant search with a
    MatchAny payload filter on the ingestion payload keys
    (``source`` / ``document_id``) — see
    ``QdrantStorageClient.search_hybrid``.
    """
    config = get_config()
    qdrant_client = QdrantStorageClient.from_config(config)

    repo_keys, source_ids = scope_filter_values(source_scope)
    has_legacy_repos = isinstance(source_scope, dict) and bool(source_scope.get("repos"))
    has_repo_scope = bool(repo_keys) or has_legacy_repos
    code_model_enabled = bool(getattr(config, "code_embedding_model_name", ""))

    sparse_query_vector = _EMBED_EXECUTOR.submit(embed_text_sparse, query_text).result()

    if code_model_enabled and has_repo_scope:
        return _search_collection(
            qdrant_client,
            config.code_qdrant_collection_name,
            query_text,
            embed_code_text,
            sparse_query_vector,
            limit,
            tenant_id,
            source_scope,
        )

    hits = _search_collection(
        qdrant_client,
        config.qdrant_collection_name,
        query_text,
        embed_text,
        sparse_query_vector,
        limit,
        tenant_id,
        source_scope,
    )

    if code_model_enabled and not source_ids:
        try:
            code_hits = _search_collection(
                qdrant_client,
                config.code_qdrant_collection_name,
                query_text,
                embed_code_text,
                sparse_query_vector,
                limit,
                tenant_id,
                source_scope,
            )
            hits.extend(code_hits)
            hits.sort(key=lambda h: h.score, reverse=True)
            hits = hits[:limit]
        except Exception as exc:
            sentry_sdk.capture_exception(exc)
            logger.debug("Optional code collection search skipped: %s", exc)

    return hits
