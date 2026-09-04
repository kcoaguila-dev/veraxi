"""
MCP dynamic web graph tool - In-Context GraphRAG for live web search.

Pipeline:
  1. Query SearXNG -> get title, url, snippet.
  2. Concurrently scrape full text of top N results.
  3. Run fast NLP extraction (SpaCy) in-memory to build a structured Knowledge Graph.
  4. Return the structured graph (nodes & relations) + source citations to the LLM.

This avoids database bloat and latency, while giving the LLM perfectly structured 
graph data to perform multi-hop reasoning on live web results.
"""
from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor

from backend.mcp_server.tools.web_search import _search_searxng, _enrich
from backend.ingestion.extract import extract_entities_and_relations_fast

logger = logging.getLogger(__name__)

# A generic robust schema for web extraction
DEFAULT_SCHEMA = {
    "entities": ["Person", "Organization", "Location", "Event", "Concept", "Product", "Date"],
    "relations": {
        "Person": {
            "Organization": ["WORKS_FOR", "FOUNDED", "MEMBER_OF"],
            "Location": ["BORN_IN", "LIVES_IN", "VISITED"],
            "Concept": ["INVENTED", "DISCOVERED", "ASSOCIATED_WITH"],
            "Event": ["PARTICIPATED_IN"]
        },
        "Organization": {
            "Location": ["HEADQUARTERED_IN", "OPERATES_IN"],
            "Organization": ["ACQUIRED", "PARTNERED_WITH", "COMPETES_WITH"],
            "Product": ["PRODUCES", "OWNS"]
        },
        "Location": {
            "Location": ["LOCATED_IN", "BORDERS"]
        },
        "Event": {
            "Location": ["OCCURRED_IN"],
            "Person": ["INVOLVED", "ATTENDED"],
            "Organization": ["HOSTED", "SPONSORED"]
        },
        "Concept": {
            "Concept": ["RELATED_TO", "CAUSES", "DEPENDS_ON"]
        },
        "Product": {
            "Organization": ["CREATED_BY"],
            "Concept": ["USES_TECHNOLOGY"]
        }
    }
}

def _extract_graph_from_result(result: dict) -> dict:
    """Extract graph from a single search result content."""
    text = result.get("content") or result.get("snippet", "")
    if not text:
        return {"url": result.get("url"), "entities": [], "relations": []}
    
    entities, relations = extract_entities_and_relations_fast(
        text=text,
        schema=DEFAULT_SCHEMA,
        language="en"
    )
    
    return {
        "url": result.get("url"),
        "title": result.get("title"),
        "entities": entities,
        "relations": relations
    }

def mcp_dynamic_web_graph(
    query: str,
    language: str = "en",
    max_results: int = 5,
    tool_settings: dict | None = None,
) -> dict:
    """
    Performs a live web search, scrapes the top pages, and dynamically extracts a 
    structured Knowledge Graph (Entities and Relationships) on the fly.

    Use this instead of standard web search when you need to answer complex, 
    multi-hop reasoning questions over live web data. It provides higher accuracy 
    and eliminates noise by structuring the web results before you process them.

    IMPORTANT: When citing sources, use inline bracketed citations containing ONLY 
    the source title EXACTLY as it appears in the 'sources' list (e.g. `[Yahoo Finance]`).

    Args:
        query: The search string.
        language: ISO 639-1 language code (default: 'en').
        max_results: Number of top results to fetch and extract (recommended 3-5).
    Returns:
        A dictionary containing 'graph' (aggregated entities and relations) and 'sources' (citations).
    """
    tool_settings = tool_settings or {}
    web_settings = tool_settings.get("web_search") or {}
    
    # 1. Search Web
    logger.info(f"Dynamic Graph Search for query: {query}")
    raw_results = _search_searxng(query, language, max_results, web_settings)
    if not raw_results:
        return {"graph": {"entities": [], "relations": []}, "sources": []}

    # 2. Enrich (Scrape full text)
    enriched_results = _enrich(raw_results, web_settings)
    
    # 3. Extract Graph in Parallel
    aggregated_entities = []
    aggregated_relations = []
    sources = []
    
    seen_entities = set()
    seen_relations = set()
    
    with ThreadPoolExecutor(max_workers=max_results) as executor:
        graphs = list(executor.map(_extract_graph_from_result, enriched_results))
        
    for g in graphs:
        sources.append({"title": g.get("title"), "url": g.get("url")})
        
        for ent in g.get("entities", []):
            ent_key = f"{ent.get('name')}_{ent.get('type')}".lower()
            if ent_key not in seen_entities:
                seen_entities.add(ent_key)
                aggregated_entities.append(ent)
                
        for rel in g.get("relations", []):
            rel_key = f"{rel.get('from_entity')}_{rel.get('type')}_{rel.get('to_entity')}".lower()
            if rel_key not in seen_relations:
                seen_relations.add(rel_key)
                aggregated_relations.append(rel)
                
    return {
        "graph": {
            "entities": aggregated_entities,
            "relations": aggregated_relations
        },
        "sources": sources
    }
