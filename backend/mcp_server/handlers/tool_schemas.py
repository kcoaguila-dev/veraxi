from mcp.types import Tool

REGISTERED_TOOLS = [
    Tool(
        name="mcp_search_vectors",
        description="[FAST - Vector Only (<50ms)] Semantic vector search over document chunks. Use when searching purely by text similarity without graph relationship traversal.",
        input_schema={
            "type": "object",
            "properties": {
                "query_text": {"type": "string"},
                "limit": {"type": "integer", "default": 10},
            },
            "required": ["query_text"],
        },
    ),
    Tool(
        name="mcp_query_graph",
        description="[FAST - Graph Only (<50ms)] Multi-hop relationship traversal from a known entity in Neo4j. Use when exploring entity connections, dependencies, or causal chains.",
        input_schema={
            "type": "object",
            "properties": {
                "entity_name": {"type": "string"},
                "max_hops": {"type": "integer", "default": 2},
            },
            "required": ["entity_name"],
        },
    ),
    Tool(
        name="mcp_insert_graph_nodes",
        description="Insert structured nodes and relations into the Neo4j Knowledge Graph. The Host AI should extract these from unstructured text first.",
        input_schema={
            "type": "object",
            "properties": {
                "nodes": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "type": {"type": "string"},
                            "name": {"type": "string"},
                            "properties": {"type": "object"},
                        },
                        "required": ["type", "name"],
                    },
                },
                "relations": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "from_entity": {"type": "string"},
                            "to_entity": {"type": "string"},
                            "type": {"type": "string"},
                        },
                        "required": ["from_entity", "to_entity", "type"],
                    },
                },
            },
            "required": ["nodes", "relations"],
        },
    ),
    Tool(
        name="mcp_insert_vectors",
        description="Generate embeddings and insert text chunks into the Qdrant Vector Database.",
        input_schema={
            "type": "object",
            "properties": {"texts": {"type": "array", "items": {"type": "string"}}},
            "required": ["texts"],
        },
    ),
    Tool(
        name="mcp_merge_rank",
        description="[DEFAULT - Fast (<100ms)] Primary hybrid GraphRAG search tool. Use for 95% of queries, codebase navigation, fact lookup, and general Q&A. Searches vector embeddings and traverses entity relationships in Neo4j.",
        input_schema={
            "type": "object",
            "properties": {
                "query_text": {
                    "type": "string",
                    "description": "Natural language query text for semantic vector search.",
                },
                "entity_name": {
                    "type": "string",
                    "description": "Optional entity name to seed graph traversal. If omitted, seeds from top vector results or runs pure vector retrieval.",
                    "default": "",
                },
                "limit": {"type": "integer", "default": 10},
                "max_hops": {"type": "integer", "default": 2},
            },
            "required": ["query_text"],
        },
    ),
    Tool(
        name="mcp_get_graph_schema",
        description="Retrieves all unique Node Labels and Relationship Types currently in the Neo4j database. Call this before inserting data to understand the current schema.",
        input_schema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="mcp_delete_entity",
        description="Deletes a specific entity and all its relationships from Neo4j.",
        input_schema={
            "type": "object",
            "properties": {"entity_name": {"type": "string"}},
            "required": ["entity_name"],
        },
    ),
    Tool(
        name="mcp_delete_document",
        description="Deletes a specific document chunk from Qdrant using its document ID.",
        input_schema={
            "type": "object",
            "properties": {"document_id": {"type": "string"}},
            "required": ["document_id"],
        },
    ),
    Tool(
        name="mcp_update_entity",
        description="Updates the properties of an existing Neo4j entity. Only provide the properties you want to add or overwrite.",
        input_schema={
            "type": "object",
            "properties": {
                "entity_name": {"type": "string"},
                "properties": {"type": "object"},
            },
            "required": ["entity_name", "properties"],
        },
    ),
    Tool(
        name="mcp_get_database_stats",
        description="Retrieves high-level statistics about the size of the database (nodes, relationships, vectors).",
        input_schema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="mcp_run_community_detection",
        description="Runs a Graph Data Science community detection algorithm to find clusters of connected entities.",
        input_schema={
            "type": "object",
            "properties": {"min_size": {"type": "integer", "default": 2}},
        },
    ),
    Tool(
        name="mcp_delete_relationship",
        description="Deletes a specific relationship edge between two entities without deleting the entities themselves.",
        input_schema={
            "type": "object",
            "properties": {
                "from_entity": {"type": "string"},
                "to_entity": {"type": "string"},
                "rel_type": {"type": "string"},
            },
            "required": ["from_entity", "to_entity", "rel_type"],
        },
    ),
    Tool(
        name="mcp_update_document_metadata",
        description="Updates or adds metadata properties to an existing vector document chunk in Qdrant.",
        input_schema={
            "type": "object",
            "properties": {
                "document_id": {"type": "string"},
                "payload": {"type": "object"},
            },
            "required": ["document_id", "payload"],
        },
    ),
    Tool(
        name="mcp_evaluate_grounding",
        description="Evaluates what percentage of a generated response is mathematically supported by the retrieved context. Returns a float between 0.0 and 1.0.",
        input_schema={
            "type": "object",
            "properties": {
                "response_text": {"type": "string"},
                "context_text": {"type": "string"},
            },
            "required": ["response_text", "context_text"],
        },
    ),
    Tool(
        name="mcp_web_search",
        description="Fallback mechanism to search the live web when internal retrieval yields insufficient context. Returns a list of JSON snippets.",
        input_schema={
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "max_results": {"type": "integer", "default": 3},
            },
        },
    ),
    Tool(
        name="mcp_skills",
        description="Lists available agentic skills for tool augmentation.",
        input_schema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="mcp_run_code",
        description="Executes Python code in a secure sandbox and returns the stdout/stderr.",
        input_schema={
            "type": "object",
            "properties": {
                "code": {"type": "string"},
            },
            "required": ["code"],
        },
    ),
    Tool(
        name="mcp_list_artifacts",
        description="Lists all artifacts stored in the workspace for the current tenant.",
        input_schema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="mcp_read_artifact",
        description="Reads the content of a specific artifact by its name.",
        input_schema={
            "type": "object",
            "properties": {
                "artifact_name": {"type": "string"},
            },
            "required": ["artifact_name"],
        },
    ),
    Tool(
        name="mcp_ingest_document",
        description="Submits a document or URL to Veraxi's native ingestion pipeline (OCR -> Graph extraction -> Insertion).",
        input_schema={
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "Absolute path to a local document file.",
                },
                "url": {
                    "type": "string",
                    "description": "URL to scrape and ingest instead of a local file.",
                },
                "fast_extraction": {"type": "boolean", "default": False},
                "language": {"type": "string", "default": "en"},
                "chunk_size": {"type": "integer", "default": 200},
                "chunk_overlap": {"type": "integer", "default": 50},
                "wait_for_completion": {
                    "type": "boolean",
                    "default": False,
                    "description": "If true, the tool will block and poll internally until ingestion is complete.",
                },
            },
        },
    ),
    Tool(
        name="mcp_get_ingest_status",
        description="Polls the status of an active ingestion job.",
        input_schema={
            "type": "object",
            "properties": {
                "job_id": {
                    "type": "string",
                    "description": "The job ID returned from mcp_ingest_document.",
                }
            },
            "required": ["job_id"],
        },
    ),
    Tool(
        name="mcp_dynamic_web_graph",
        description="Dynamic Web Search GraphRAG - searches the web and returns a structured Knowledge Graph of entities and relations instead of raw text snippets, allowing for high-accuracy multi-hop reasoning over live data.",
        input_schema={
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "language": {"type": "string", "default": "en"},
                "max_results": {"type": "integer", "default": 5},
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="mcp_ephemeral_web_rag",
        description="[DEEP WEB CRAWL & RAG - Moderate (3-8s)] Full-page web crawler and temporary GraphRAG indexer. DO NOT use for simple fact lookups or finding links (use native host web search for that). Use this when you need to read FULL contents of external documentation, articles, or URLs (pass in 'urls' array), extract their entities into a temporary sandboxed graph, and perform structured RAG over the crawled text.",
        input_schema={
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "max_results": {"type": "integer", "default": 3},
                "urls": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional list of pre-searched URLs to ingest and research over. If provided, skips the internal web search phase.",
                },
            },
        },
    ),
    Tool(
        name="mcp_agentic_debate",
        description="[HEAVY - Long Running (15-30s)] Multi-agent debate swarm with adversarial Skeptic fact-checking. Dispatches Vector, Knowledge Graph, and Web specialists, synthesizes evidence with strict citations, and enforces an adversarial verification loop. ONLY call when the user explicitly asks for 'deep research', 'exhaustive audit', or 'multi-agent debate'. Do not use for routine lookups.",
        input_schema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The research question or topic to investigate.",
                },
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="mcp_export_data",
        description="Serializes and exports dynamically structured datasets into agnostic, interoperable file formats (CSV, OTIO, FCPXML). Facilitates seamless data handoff to external analytical pipelines, data science environments, and professional non-linear editing (NLE) systems without imposing domain-specific schemas.",
        input_schema={
            "type": "object",
            "properties": {
                "data": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "description": "Any structured data dictionary. If exporting to otio/fcpxml, include start_time, duration, character, dialogue, audio_path.",
                        "additionalProperties": True,
                    },
                },
                "format": {
                    "type": "string",
                    "enum": ["csv", "otio", "fcpxml"],
                    "default": "csv",
                },
                "output_name": {"type": "string", "default": "veraxi_export"},
            },
            "required": ["data"],
        },
    ),
    Tool(
        name="mcp_build_lazy_dossier",
        description="Extracts a comprehensive research dossier from ingested documents using Hybrid Vector Search (Dense + SPLADE) fused with existing Neo4j entity anchors. Generates structured evidence chunks and instructions for Host AI to extract high-precision causal triples.",
        input_schema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The research query or topic (e.g. 'David Einhorn investigation of Allied Capital loan valuations')",
                },
                "limit": {
                    "type": "integer",
                    "default": 15,
                    "description": "Number of evidence chunks to retrieve",
                },
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="mcp_purge_noisy_relationships",
        description="Purges all raw sentence-level co-occurrence ('MENTIONED_WITH') relationships from Neo4j for the current tenant. Leaves all entity nodes, book titles, and Qdrant vector links intact to eliminate graph noise.",
        input_schema={
            "type": "object",
            "properties": {},
        },
    ),
]
