# 2. Use Neo4j and Qdrant for Dual-Engine Intelligence

Date: 2026-07-15

## Status

Accepted

## Context

Veraxi requires an intelligence system capable of giving an LLM autonomous access to both relational data (how entities are connected) and semantic data (what text means).
Using a traditional SQL database (like PostgreSQL) makes traversing highly connected graphs incredibly slow and requires complex `JOIN` statements that are difficult for an LLM to reliably generate. Using *only* a Vector Database limits the LLM's ability to understand strict hierarchies and relationships.

## Decision

We will use a dual-engine storage architecture:
1. **Neo4j:** To store structured entities and relationships as a Knowledge Graph.
2. **Qdrant:** To store the semantic embeddings (vectors) of those entities.

These two engines will be merged at query-time using Reciprocal Rank Fusion (RRF) in the `merge_rank.py` module. Furthermore, every Neo4j node must rigidly store its corresponding Qdrant Point ID to maintain synchronization.

## Consequences

**Positive:**
- The LLM gains "hybrid search" capabilities, cross-referencing strict relationships with fuzzy semantic similarities.
- Neo4j provides a native graph traversal language (Cypher) that is highly optimized for multi-hop relationship queries.

**Negative:**
- Increased operational complexity. We must run and maintain two separate database engines.
- Ingestion logic is complex; we must ensure distributed transactions (if Neo4j writes succeed but Qdrant fails, we risk orphaned data).
