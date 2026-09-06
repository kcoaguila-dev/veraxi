import logging
from concurrent.futures import ThreadPoolExecutor

from backend.config import get_config
from backend.mcp_server.tools.ingest_document import mcp_ingest_document
from backend.mcp_server.tools.search_providers import get_search_provider
from backend.retrieval.merge_rank import merge_rank
from backend.mcp_server.tools.search_vectors import search_vectors
from backend.mcp_server.tools.query_graph import query_graph
from backend.storage.neo4j_client import Neo4jStorageClient
from backend.storage.qdrant_client import QdrantStorageClient
import redis
import uuid
import dataclasses
logger = logging.getLogger(__name__)

def mcp_deep_research(
    query: str,
    tenant_id: str,
    max_results: int = 3,
    urls: list[str] | None = None,
    tool_settings: dict | None = None,
) -> dict:
    """
    Performs deep web research by searching the web, dynamically ingesting the top
    results into the tenant's Hybrid RAG database, and returning the mathematically 
    ranked RRF results using `merge_rank`.
    """
    tool_settings = tool_settings or {}
    web_settings = tool_settings.get("web_search") or {}
    
    logger.info(f"Deep Research triggered for query: '{query}' on original tenant: {tenant_id}")
    
    # 1. Generate Ephemeral Namespace
    ephemeral_tenant_id = f"ephemeral_res_{uuid.uuid4().hex[:8]}"
    logger.info(f"Created ephemeral namespace: {ephemeral_tenant_id}")
    
    # 2. Search the web (if urls not provided)
    if not urls:
        provider = get_search_provider(web_settings)
        raw_results = provider.search(query, language="en", max_results=max_results, web_settings=web_settings)
        
        if not raw_results:
            logger.warning(f"No results found for query: {query}")
            return {"error": "No search results found.", "query": query, "results": []}

        urls = [res.get("url") for res in raw_results if res.get("url")]
        
    if not urls:
        return {"error": "No valid URLs found to ingest.", "query": query, "results": []}

    logger.info(f"Deep Research found {len(urls)} URLs. Ingesting concurrently into {ephemeral_tenant_id}...")

    config = get_config()
    
    # Clone schema to ephemeral tenant
    r = redis.Redis.from_url(config.redis_url)
    schema_data = r.get(f"tenant:{tenant_id}:schema")
    if schema_data:
        r.set(f"tenant:{ephemeral_tenant_id}:schema", schema_data)
        
    ingestion_results = []
    
    try:
        # 3. Concurrently Ingest URLs
        def _ingest_url(url: str):
            logger.info(f"Ingesting URL: {url}")
            return mcp_ingest_document(
                tenant_id=ephemeral_tenant_id,
                url=url,
                fast_extraction=True,  # Force fast extraction for speed during on-the-fly search
                language="en",
                wait_for_completion=True
            )

        with ThreadPoolExecutor(max_workers=max_results) as executor:
            for res in executor.map(_ingest_url, urls):
                ingestion_results.append(res)
                
        logger.info(f"Deep Research ingestion complete in {ephemeral_tenant_id}. Running merge_rank...")

        # 4. Perform Hybrid RAG Retrieval (merge_rank)
        
        # Perform standard vector search
        v_hits = search_vectors(
            query_text=query,
            limit=config.default_search_limit,
            tenant_id=ephemeral_tenant_id
        )
        
        # We use the search query as a best-effort entity name for the graph query.
        g_hits = query_graph(
            entity_name=query,
            max_hops=config.default_max_hops,
            tenant_id=ephemeral_tenant_id
        )
        
        # Fuse results using Reciprocal Rank Fusion
        results = merge_rank(v_hits, g_hits, limit=config.default_search_limit)
        
        dict_results = [dataclasses.asdict(r) for r in results]
        
        return {
            "query": query,
            "urls_ingested": urls,
            "ingestion_statuses": [res.get("status") or res.get("error") for res in ingestion_results],
            "results": dict_results
        }
        
    finally:
        # 5. Aggressive Cleanup (Zero Data Pollution)
        logger.info(f"Deep Research complete. Wiping ephemeral tenant: {ephemeral_tenant_id}")
        
        try:
            # Delete Neo4j nodes
            neo4j_client = Neo4jStorageClient.from_config(config)
            neo4j_client.execute_write(
                "MATCH (n) WHERE n.tenant_id = $tenant_id DETACH DELETE n",
                {"tenant_id": ephemeral_tenant_id}
            )
            neo4j_client.close()
            
            # Delete Qdrant vectors
            qdrant_client = QdrantStorageClient.from_config(config)
            qdrant_client.delete_tenant(config.qdrant_collection_name, ephemeral_tenant_id)
            
            # Delete Redis schema
            r.delete(f"tenant:{ephemeral_tenant_id}:schema")
            
            logger.info(f"Successfully wiped ephemeral tenant: {ephemeral_tenant_id}")
        except Exception as e:
            logger.error(f"Failed to wipe ephemeral tenant {ephemeral_tenant_id}: {e}")
            import sentry_sdk
            sentry_sdk.capture_exception(e)
