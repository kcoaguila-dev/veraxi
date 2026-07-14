# Veraxi

A sovereign intelligence platform that combines a knowledge graph (Neo4j) and vector search (Qdrant) to give an LLM (Gemini 2.5 Flash) autonomous, tool-based access to both relational and semantic context.

Veraxi utilizes Reciprocal Rank Fusion (RRF) to merge structured graph lookups and semantic vector similarities into a single, high-fidelity context window, allowing the LLM to deduce deep architectural and organizational realities without hallucinating.

## 🚀 Status

**Phase 8 Complete: Veraxi is fully functional with arbitrary document ingestion and Dockerized deployment.**
The project now features a complete multi-tenant architecture, a Flutter UI with a Control Panel for ingestion, and a 1-click self-hostable Docker configuration.

See [docs/ROADMAP.md](docs/ROADMAP.md) for the full phase history.

## Screenshots
![Control Panel](docs/assets/control_panel.png)

## 🏗 Architecture

See [docs/architecture.md](docs/architecture.md) for a deep dive into the dependency flow and design rules.

- **Storage:** Neo4j (Graph), Qdrant (Vectors)
- **Intelligence:** Google GenAI SDK (Gemini 2.5 Flash)
- **Entity Resolution:** Splink
- **Backend API Gateway:** FastAPI
- **Frontend:** *(In Development)* Flutter (Dart), Riverpod

## 💻 Can I run this for free?

**Yes!** 
- The databases (Neo4j and Qdrant) run entirely locally for free via Docker.
- The intelligence engine uses the **Google Gemini API**, which currently offers a **very generous Free Tier** (up to 15 RPM for Gemini 2.5 Flash). 

Anyone can clone this repo and run their own autonomous intelligence substrate on their local machine at absolutely no cost.

## 🛠 Quickstart Setup

1. **Clone and enter the repository:**
   ```bash
   git clone https://github.com/kcoaguila-dev/veraxi.git
   cd veraxi
   ```

2. **Start the databases:**
   ```bash
   docker compose up -d
   ```
   *(This spins up local, ephemeral instances of Neo4j and Qdrant).*

3. **Configure the environment:**
   Copy the example config and add your **free** Gemini API key.
   ```bash
   cp backend/.env.example backend/.env
   # Edit backend/.env and add your GEMINI_API_KEY
   ```

4. **Install Python dependencies:**
   ```bash
   python3 -m venv backend/.venv
   source backend/.venv/bin/activate
   cd backend
   pip install -e ".[dev]"
   cd ..
   ```

## 🧠 Using the Backend

Veraxi is currently headless while we build the Flutter UI, but it is 100% fully functional right now. 

You have two ways to interact with it:

### 1. Interactive Command Line
Ask Veraxi a question directly from the terminal. The LLM will autonomously decide whether to search vectors, query the graph, or both.
```bash
source backend/.venv/bin/activate
python -m scripts.ask_veraxi "What is Veraxi?"
```

### 2. Self-Hostable API Gateway
Run Veraxi as a background REST API so other applications (like the upcoming Flutter frontend) can query it over the network.
```bash
./scripts/start_server.sh
```
Once running, you can hit the endpoint from any terminal:
```bash
curl -X POST http://localhost:8000/api/chat \
  -H "Content-Type: application/json" \
  -d '{"question": "What is Veraxi?"}'
```

## Contributing
We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for step-by-step instructions on setting up your local environment and understanding our strict architectural guidelines.

## License
MIT — see [LICENSE](LICENSE).