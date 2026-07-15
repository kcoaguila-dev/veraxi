# Veraxi

A sovereign intelligence platform that combines a knowledge graph (Neo4j) and vector search (Qdrant) to give an LLM (Gemini 2.5 Flash) autonomous, tool-based access to both relational and semantic context.

Veraxi utilizes Reciprocal Rank Fusion (RRF) to merge structured graph lookups and semantic vector similarities into a single, high-fidelity context window, allowing the LLM to deduce deep architectural and organizational realities without hallucinating.

## Status

**Phase 13 Complete: Sovereign Cross-Platform Architecture is Production-Ready.**
The backend infrastructure, data extraction pipeline, and LLM orchestration loop are fully functional. 
The Flutter frontend has been upgraded to a secure, persistent, cross-platform app featuring Generative UI (Cytoscape.js) and local SQLite storage.

See [docs/ROADMAP.md](docs/ROADMAP.md) for the current active phase.

## Architecture

See [docs/architecture.md](docs/architecture.md) for a deep dive into the dependency flow and design rules.

- **Storage:** Neo4j (Graph), Qdrant (Vectors), SQLite (UI Persistence)
- **Intelligence:** Google GenAI SDK (Gemini 2.5 Flash)
- **Backend API Gateway:** FastAPI
- **Frontend:** Flutter (Dart), Riverpod, flutter_secure_storage (libsecret)
- **CI/CD:** Ephemeral Docker Environments (GCP Staging)

## Can I run this for free?

**Yes!** 
- The databases (Neo4j and Qdrant) run entirely locally for free via Docker.
- The intelligence engine uses the **Google Gemini API**, which currently offers a **very generous Free Tier** (up to 15 RPM for Gemini 2.5 Flash). 

Anyone can clone this repo and run their own autonomous intelligence system on their local machine at absolutely no cost.

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

## Using the Backend

You have three ways to interact with it:

### 1. The Flutter Desktop/Mobile App (Recommended)
The primary way to use Veraxi is through its beautiful, interactive cross-platform UI.
```bash
cd app
flutter pub get
flutter run -d linux
```
*(Note: Linux users must have `libsecret-1-dev` installed on the host OS for secure keychain access).*

#### Running on Android (Network Configuration)
If you run Veraxi on an Android device, the app cannot hit `localhost` because the backend is running on your desktop. You must pass your desktop's local IP address (e.g., `192.168.1.15`) dynamically at compile time:
```bash
flutter run -d android --dart-define=API_URL=http://192.168.1.15:8000
```

### 2. Interactive Command Line
Ask Veraxi a question directly from the terminal. The LLM will autonomously decide whether to search vectors, query the graph, or both.
```bash
source backend/.venv/bin/activate
python -m scripts.ask_veraxi "What is Veraxi?"
```

### 3. Fully Automated Containerized Backend
If you want to run the entire backend (Neo4j, Qdrant, and the Python MCP API Gateway) without installing Python or dealing with virtual environments, you can run the entire stack with a single command:
```bash
docker-compose up -d --build
```
Once running, the API Gateway is instantly available at `http://localhost:8000`!

## 🧪 Containerized Testing

Veraxi enforces a strict **Zero-Warning** CodeScene policy. We guarantee 100% reproducible test environments by containerizing both the frontend and backend testing pipelines.
To run the full suite (including `flutter analyze`, `flutter test`, and `pytest`) in an ephemeral Docker environment:
```bash
make test-gcp
```

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md).

## License
MIT — see [LICENSE](LICENSE).