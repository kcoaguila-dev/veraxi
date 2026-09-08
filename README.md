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

To validate the Hybrid GraphRAG approach, Veraxi includes an automated DeepEval (LLM-as-a-judge) benchmark suite (`backend/evaluation/benchmark_rag.py`) that scores Vector RAG against Hybrid GraphRAG on a medical test corpus.

**Latest Benchmark Results (`dataset.json`):**
- **Average Vector RAG Correctness:** 45.0%
- **Average Hybrid GraphRAG Correctness:** 90.0%

*Note: This evaluation runs on a small proof-of-concept dataset (10 questions, ~300 words). While it successfully demonstrates the RRF fusion algorithm overcoming Vector RAG's limitations on multi-hop reasoning, a true production deployment requires scaling this benchmark to a massive corpus (e.g., Needle In A Haystack).*

## Architecture

- **Storage:** Neo4j (Graph), Qdrant (Vectors), SQLite (UI Persistence)
- **Intelligence:** OpenAI-compatible SDK (OpenAI, Gemini, Groq, Local Models via Ollama)
- **Backend Engine:** FastAPI, Python
- **Frontend:** Flutter (Dart), Riverpod

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
