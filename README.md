# Veraxi

Veraxi is an experimental reference architecture that demonstrates how to implement **Hybrid GraphRAG** by combining a knowledge graph (Neo4j) with vector search (Qdrant) and merging the results using Reciprocal Rank Fusion (RRF). 

It is designed to give an LLM autonomous, tool-based access to both relational and semantic context, reducing hallucinations on complex multi-hop queries. The backend is built with FastAPI and the frontend is a cross-platform Flutter application.

## 🌐 Live Demo
- **Frontend (Flutter Web):** [https://veraxi.me](https://veraxi.me)
- **Backend API (FastAPI):** Google Cloud Run

![Veraxi UI](docs/images/demo.png)

## Why Hybrid GraphRAG? (Architectural Tradeoffs)

Deploying Veraxi involves a fundamental tradeoff: **increased upfront ingestion complexity** in exchange for **deterministic multi-hop reasoning**. 

Standard Vector RAG retrieves text chunks based on mathematical closeness (cosine similarity). This often fails when answers require synthesizing facts across non-adjacent documents (multi-hop queries), leading to the "Similarity Trap" where distractor chunks score higher than the actual truth.

**Hybrid GraphRAG** addresses this by explicitly mapping entities during ingestion:
`John Smith` → `[FOUNDED]` → `Acme Corp` → `[ACQUIRED_BY]` → `GlobalTech` → `[HAS_CEO]` → `Jane Doe`. 

By traversing hard mathematical edges alongside semantic vector search, the LLM retrieves the exact isolated documents needed to answer the query, reducing hallucination.

### ⚠️ Scope & Limitations
While Veraxi includes features like multi-tenancy, JWT auth, Stripe billing scaffolds, and GPT-SoVITS TTS integration, **these are structural boilerplates for developers**, not battle-tested enterprise systems. 

Veraxi's primary value is serving as a deployable integration of the Neo4j + Qdrant RRF pipeline. The surrounding "SaaS" surface area exists to demonstrate how to wire a Hybrid GraphRAG pipeline into a real user-facing application.

## 📊 Evaluation & Benchmarks

Veraxi includes an automated [DeepEval](https://github.com/confident-ai/deepeval) (LLM-as-a-judge) benchmark suite that scores Vector RAG against Hybrid GraphRAG on a medical test corpus (`backend/evaluation/benchmark_rag.py`).

**Latest Live Benchmark Results** (4/10 test cases scored — remaining 6 were rate-limited by Gemini free-tier quota):

| Query | Vector RAG | Hybrid GraphRAG |
|---|---|---|
| Most common type of skin cancer? | 1.00 | 1.00 |
| Which cell type does BCC arise from? | 0.60 | 0.70 |
| Anatomical locations affected? | 0.70 | 0.70 |
| Primary risk factor? | 1.00 | 1.00 |
| **Average (n=4)** | **82.5%** | **85.0%** |

> **Honesty note:** This corpus is small (~300 words, 26 chunks) and the questions are straightforward enough that vector search alone performs well. The real value of graph traversal shows on multi-hop queries over larger corpora where relevant chunks are semantically distant — this test set doesn't yet stress that case. 
> 
> **Evaluation Infrastructure Status:** A massive 2,062-question pipeline (`run_full_suite.sh`) and a zero-cost deterministic 150-question pipeline (`run_deterministic_suite.sh`) have been built and committed. The deterministic suite uses true stratified sampling and F1 token-overlap (ROUGE-1) to bypass LLM-as-a-judge API costs. However, executing either suite requires ~600+ API generation calls, which currently exceeds the strict 20 Requests Per Day limit on the free-tier `gemini-3.6-flash` model. 
> 
> **Metric Caveat:** The F1 token-overlap metric is excellent for fact retrieval, but degrades on "Level 4: Creative Generation" questions where fluent paraphrasing correctly scores low due to exact-match penalties. This is a known limitation of deterministic metrics on open-ended RAG evaluations.
> 
> To run the full benchmark, provision a paid API key and execute: `PYTHONPATH=. python -m backend.evaluation.benchmark_rag`

## Architecture

- **Storage:** Neo4j (Graph), Qdrant (Vectors), SQLite (UI Persistence)
- **Intelligence:** OpenAI-compatible SDK (OpenAI, Gemini, Groq, Local Models via Ollama)
- **Backend Engine:** FastAPI, Python (ASGI SSE / Remote MCP)
- **Frontend:** Flutter (Dart), Riverpod

### ⚡ Just-In-Time (Lazy) GraphRAG Architecture

To eliminate the prohibitive computational cost and "hairball" graph noise of traditional upfront GraphRAG, Veraxi implements a **two-tier Just-In-Time (Lazy) GraphRAG** pipeline:

1. **Tier 1 — Base Ingestion (CPU-Optimized, Free):**
   * Raw text (PDFs, Markdown, text files) is chunked and indexed into Qdrant using dual embeddings: **MiniLM (dense semantics)** and **SPLADE (lexical keywords)**.
   * Lightweight entity anchors (companies, people, metrics, source titles) are mapped into Neo4j with **bidirectional UUID links** (`qdrant_point_id` ↔ `neo4j_node_ids`).
   * Spurious sentence-level co-occurrence edges (`MENTIONED_WITH`, `WORKS_FOR`) are skipped, keeping ingestion under **2 minutes per 500-page book** on pure CPU with 0 GPU VRAM.

2. **Tier 2 — On-Demand Causal Graph Weaving (Just-In-Time):**
   * When researching a topic or complex multi-hop question, the Host AI (via Claude Code, Cursor, or Antigravity) retrieves seed chunks via `mcp_build_lazy_dossier`.
   * The frontier subscription model extracts high-precision, verified **causal relationships** (e.g. `(Einhorn)-[:INVESTIGATED]->(Allied Capital)`) and commits them via `mcp_insert_graph_nodes`.
   * The graph grows organically into a curated, high-signal knowledge base without upfront API bills.

### 🛠 Core MCP Tools

Veraxi exposes its hybrid engine over standard Model Context Protocol (MCP) endpoints (`/sse`):

| Tool | Purpose |
| :--- | :--- |
| `mcp_build_lazy_dossier` | Retrieves ground-truth excerpts via Hybrid Search (Dense + SPLADE) fused with Neo4j entity anchors, returning a structured analytical dossier. |
| `mcp_insert_graph_nodes` | Upserts/merges structured causal entities and rich relations into Neo4j, preserving Qdrant vector links without duplicates. |
| `mcp_merge_rank` | Executes 3-way hybrid search: Qdrant dense + sparse vectors combined with Neo4j multi-hop traversals via Reciprocal Rank Fusion (RRF). |
| `mcp_purge_noisy_relationships` | Purges uncurated co-occurrence edges from Neo4j for a tenant while keeping all entity nodes and vector links intact. |
| `mcp_get_database_stats` | Live counts of nodes, vectors, and relationships for the current tenant. |
| `mcp_export_data` | Exports structured timelines and research into CSV, OpenTimelineIO (`.otio`), or Final Cut Pro XML (`.fcpxml`). |

### 📚 Batch Document Ingestion

To ingest folders of books, 10-K filings, or research PDFs in bulk:
```bash
python -m backend.scripts.batch_ingest --dir /path/to/documents --tenant <tenant_id> --fast --chunk-size 600 --chunk-overlap 100
```

See [docs/architecture.md](docs/architecture.md) for a deep dive into the dependency flow and design rules.

## 🛠 Quickstart Setup (Local Development)

You can run the databases locally for free via Docker and connect to free-tier cloud models (Gemini, Groq) or local models (Ollama).

1. **Clone and enter the repository:**
   ```bash
   git clone https://github.com/kcoaguila-dev/veraxi.git
   cd veraxi
   ```

2. **Start the databases (Neo4j, Qdrant, Redis, SearxNG):**
   ```bash
   docker compose up -d neo4j qdrant redis searxng
   ```

3. **Configure the environment:**
   ```bash
   cp backend/.env.example backend/.env
   # Edit backend/.env and add your LLM_API_KEY
   ```

4. **Install Python dependencies and run:**
   ```bash
   python3 -m venv backend/.venv
   source backend/.venv/bin/activate
   cd backend
   pip install -e ".[dev]"
   uvicorn main:app --reload
   ```

5. **Run the Flutter App:**
   ```bash
   cd app
   flutter pub get
   flutter run -d linux
   ```

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md).

## License
MIT — see [LICENSE](LICENSE).
