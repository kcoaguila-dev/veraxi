# Veraxi

A sovereign intelligence platform that combines a knowledge graph (Neo4j) and vector search (Qdrant) to give an LLM autonomous, tool-based access to both relational and semantic context. Supports Cloud APIs (OpenAI, Anthropic, Google, Groq, DeepSeek, Kimi) and Local AI models (Ollama, LM Studio).

Veraxi utilizes Reciprocal Rank Fusion (RRF) to merge structured graph lookups and semantic vector similarities into a single, high-fidelity context window, allowing the LLM to deduce deep architectural and organizational realities with significantly reduced hallucination risk.

## 🌐 Live Demo
Veraxi is currently deployed and live!
- **Frontend (Flutter Web):** [https://veraxi.me](https://veraxi.me) (Hosted on GitHub Pages)
- **Backend API (FastAPI):** `https://veraxi-backend-877632476404.us-east4.run.app` (Hosted on Google Cloud Run)

![Veraxi UI](docs/images/demo.png)

## Why Hybrid GraphRAG? (Architectural Tradeoffs)

Choosing to deploy Veraxi means accepting a fundamental tradeoff: **increased upfront ingestion complexity** in exchange for **deterministic multi-hop reasoning**. 

Standard Vector RAG is excellent for broad semantic search but suffers from the "Similarity Trap": it retrieves chunks based on mathematical closeness, which often fails when answers require synthesizing facts across non-adjacent documents (multi-hop queries).

### The Multi-Hop Problem

Consider a scenario where information is fragmented:
1. *"The startup Acme Corp was founded by John Smith in 2010."*
2. *"Jane Doe is the CEO of GlobalTech, which acquired Acme Corp in 2015."*

If a user asks: **"Who is the CEO of the company that acquired the startup founded by John Smith?"**

- **Standard Vector RAG** relies on semantic overlap. It may rank a distractor chunk containing keywords like "CEO," "acquired," and "startup" higher than the actual truth, failing to connect the fragmented facts and leading to hallucination.
- **Hybrid GraphRAG** addresses this by explicitly mapping the entities: `John Smith` → `[FOUNDED]` → `Acme Corp` → `[ACQUIRED_BY]` → `GlobalTech` → `[HAS_CEO]` → `Jane Doe`. By traversing hard mathematical edges, it bypasses semantic ambiguity, pulling the exact isolated documents needed to answer the query.

### Realities and Limitations

While Hybrid GraphRAG dramatically reduces hallucinations for complex queries, it is not a silver bullet. A senior engineering evaluation of Veraxi must account for the following realities:

1. **Extraction Bottlenecks:** Graph traversal is only as good as the data ingested. If the LLM extraction pipeline fails to identify an entity or relationship, the graph will have broken links.
2. **Schema Rigidity & Maintenance:** Unlike Vector RAG, where you blindly dump text into an index, GraphRAG requires defining and maintaining a consistent ontology (Node Labels and Edge Types). As data evolves, the graph requires active curation.
3. **High Upfront Compute Cost:** Extracting nodes and edges from unstructured text requires heavy LLM usage during ingestion. (To mitigate this, Veraxi supports a **Bring Your Own Subscription (BYOS)** model via the Model Context Protocol (MCP), allowing clients to offload extraction costs to existing AI assistants).
When configured correctly, the Hybrid approach (merging Graph traversal with Vector semantic search via Reciprocal Rank Fusion) yields significant, mathematically verifiable improvements. According to independent industry benchmarks:
- **Microsoft Research** demonstrated that GraphRAG significantly outperforms standard RAG on global, corpus-spanning queries by explicitly tracking entity networks ([*From Local to Global: A Graph RAG Approach to Query-Focused Summarization*](https://arxiv.org/abs/2404.16130)).
- The **UK National Innovation Centre for Data (NICD)** found that integrating GraphRAG made AI agents **80% more "truthful"** (reducing hallucinations) and enabled them to answer more than twice as many complex queries compared to standard vector-only RAG pipelines.

### Web GraphRAG (Ephemeral extraction)
For live web searches, standard RAG dumps raw text snippets into the LLM context, which quickly causes hallucinations due to the "lost-in-the-middle" effect. To solve this, Veraxi performs **In-Context GraphRAG**:
1. It uses your preferred search provider (e.g., SearXNG or Tavily).
2. It scrapes the full pages and dynamically extracts a Knowledge Graph in-memory using a lightning-fast, zero-inference-cost NLP pipeline (powered by `spaCy`).
3. It passes this perfectly structured JSON graph back to the Host AI (the model you are currently chatting with) to perform the actual reasoning. 

**Zero Data Pollution:** Unlike user-ingested documents, these web graphs are strictly **ephemeral**. They are processed in-memory for the duration of the query and immediately discarded. This ensures your permanent Neo4j database is never polluted with untrusted or random web data without your explicit permission, aligning with how leading enterprise search engines (like Glean and Perplexity) separate internal enterprise truth from live web retrieval.

### Enterprise Architectural Validation & The Open-Source Gap
While the theoretical benefits of GraphRAG are well-documented, the open-source ecosystem is currently flooded with fragmented Python scripts or expensive cloud platforms. There is a distinct lack of out-of-the-box, full-stack GraphRAG applications that are ready for immediate production use.

Veraxi fills this gap by strictly implementing **Neo4j's official Hybrid Retrieval architecture**. Neo4j's official engineering guidelines dictate that the most robust RAG pipelines run multi-modal retrieval (Semantic Vector Search + Structural Graph Traversal) in parallel, and merge the incompatible scoring outputs using the **Reciprocal Rank Fusion (RRF)** formula. Veraxi provides this enterprise-grade pipeline as a deployable product, not just a proof of concept.

## Who is this for? (Use Cases)

Because Veraxi provides enterprise-grade data structures at zero API cost (via BYOS), it is the perfect tool for:

1. **Educators & Content Creators:** Feed Veraxi hundreds of research papers, articles, or transcripts to synthesize complex topics. By relying on explicitly defined graph edges rather than pure semantic guessing, you can drastically reduce hallucinations and generate highly accurate, long-form scripts and deep-dives for social media or YouTube.
2. **Researchers & Analysts:** Standard RAG fails when analyzing legal contracts, medical journals, or financial reports because it loses track of entities. Veraxi's graph allows you to ask complex questions like *"Which companies in this corpus are exposed to supply chain risk X?"* and get deterministic answers.
3. **Independent Developers & Consultants:** Build and evaluate state-of-the-art Hybrid GraphRAG systems for your clients without spending thousands of dollars on expensive enterprise AI platform subscriptions.
## Status

**v1.0.0 (MVP Live)**
The Veraxi platform MVP has been successfully completed and deployed to production. 

Features successfully implemented so far include:
- A multi-tenant FastAPI engine featuring Stripe webhook integration and secure JWT authentication.
- Tenant-Specific Dynamic Ontologies: A strict, user-defined graph schema enforced during ingestion, with LLM auto-generation for effortless setup.
- Docling-powered multimodal ingestion and an SSE-based Model Context Protocol (MCP) transport layer with dynamic rate limiting.
- A premium, modern, cross-platform Flutter client featuring zero-config UI support for both Cloud APIs (OpenAI, Anthropic, Google, Groq, DeepSeek, Kimi) and Local AI providers (e.g. Ollama, LM Studio).
- Corrective Retrieval Augmented Generation (CRAG) with web search fallback and LLM-as-a-judge grounding evaluation.
- **Enterprise Isolation Mode:** Built-in SSRF protection and UI lockdown for corporate environments (via the `IS_ENTERPRISE` flag) where administrators dictate endpoints and end-users cannot alter model routing.

See [docs/ROADMAP.md](docs/ROADMAP.md) for the historical evolution of the project.

## Architecture

See [docs/architecture.md](docs/architecture.md) for a deep dive into the dependency flow and design rules.

- **Storage:** Neo4j (Graph), Qdrant (Vectors), SQLite (UI Persistence)
- **Intelligence:** OpenAI-compatible SDK (Multiple Cloud Providers & Local LLMs)
- **Backend Intelligence Engine:** FastAPI
- **Frontend:** Flutter (Dart), Riverpod, flutter_secure_storage (libsecret)
- **CI/CD:** Ephemeral Docker Environments (GCP Staging)

## Can I run this for free?

**Yes!**
- The databases (Neo4j and Qdrant) run entirely locally for free via Docker.
- The intelligence engine connects dynamically to any OpenAI-compatible API, meaning you can run models entirely locally (via Ollama or LM Studio) for 100% free, private inference.
- If you prefer cloud APIs, you can use the **Google Gemini API** or **Groq API**, which currently offer **very generous Free Tiers**.

Anyone can clone this repo and run their own autonomous intelligence system on their local machine at absolutely no cost.

## 🛠 Quickstart Setup (Local Development)

1. **Clone and enter the repository:**
   ```bash
   git clone https://github.com/kcoaguila-dev/veraxi.git
   cd veraxi
   ```

2. **Start the databases & infrastructure:**
   ```bash
   docker compose up -d neo4j qdrant redis searxng
   ```
   *(This spins up local, ephemeral instances of Neo4j, Qdrant, Redis, and SearxNG without the backend, allowing you to run the Python server locally).*

3. **Configure the environment:**
   Copy the example config and add your preferred API keys.
   ```bash
   cp backend/.env.example backend/.env
   # Edit backend/.env and add your LLM_API_KEY (e.g., OpenAI, Gemini, Groq, or Local)
   ```

4. **Install Python dependencies:**
   ```bash
   python3 -m venv backend/.venv
   source backend/.venv/bin/activate
   cd backend
   pip install -e ".[dev]"
   cd ..
   ```

## 🎙️ GPT-SoVITS Voice Integration (Self-Hosted)

Veraxi fully supports external, self-hosted **GPT-SoVITS** inference nodes to provide natural Text-to-Speech (TTS) capabilities.

The architecture strictly decouples the **infrastructure** from the **end-user**:

1. **Infrastructure:** Stand up a GPT-SoVITS inference node (e.g., via Ngrok or a local IP) and make sure your reference audio files are accessible to it.
2. **End-Users:** Open the Veraxi app, navigate to **Settings -> Speech**, select **GPT-SoVITS**, and input the URL of your running inference node. You can then click **Manage Voices** directly in the UI to dynamically add, edit, or delete custom voice personas—complete with their relative audio paths and prompt metadata—without ever touching the backend code or config files!

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

### 3. Fully Automated Containerized Stack
If you want to run the entire stack (Neo4j, Qdrant, Redis, the Python FastAPI Engine, and the Flutter Web UI) without installing Python or dealing with virtual environments, you can run everything with a single command:
```bash
docker compose up -d --build
```
Once running, the Intelligence Engine API is available at `http://localhost:8000` and the Web UI at `http://localhost:80`!

### 🏢 Enterprise Deployment Mode

If deploying Veraxi for an entire company or school, you can activate Enterprise Mode by setting `IS_ENTERPRISE=true` in your `docker-compose.yml` environment.
When active:
- The UI automatically hides all AI provider configuration and API Key settings.
- The backend strictly enforces the endpoints defined in the `.env` file, actively dropping any malicious URL overrides sent by clients (preventing SSRF).
- Administrators configure models globally once, and all employees inherit them seamlessly.

### 4. Self-Hosted / Open-Source Desktop Clients
If you are an open-source contributor and want to connect the official Claude Desktop app or Cursor directly to your local instance without routing through the Intelligence Engine, you can use the lightweight `stdio` runner.

Simply add this to your `claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "veraxi": {
      "command": "python",
      "args": ["-m", "backend.mcp_server"]
    }
  }
}
```
*Note: Make sure to run this command from the root `veraxi` directory so that Python can resolve the `backend` package.*

## Containerized Testing

Veraxi enforces a strict **Zero-Warning** CodeScene policy. We guarantee 100% reproducible test environments by containerizing both the frontend and backend testing pipelines.
To run the full suite (including `flutter analyze`, `flutter test`, and `pytest`) in an ephemeral Docker environment:
```bash
make test-gcp
```

### ⚠️ Production RAG Evaluation
The repository includes a baseline "Golden Dataset" (`backend/evaluation/dataset.json`) and a matching test corpus (`graphrag_test_corpus.txt`) used by DeepEval to test the hybrid RAG engine. 

**Before deploying Veraxi to production on your company's data, you MUST:**
1. Replace the test corpus with a massive, industry-standard dataset (e.g., **Paul Graham's Essays** or the **Needle In A Haystack** benchmark). 
2. Update the Golden Dataset to reflect the new text. 

A 300-word test corpus is insufficient for testing true Vector Retrieval Precision. RAG engines must be stressed with thousands of chunks of distractor "noise" to mathematically prove they do not hallucinate.

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md).

## License
MIT — see [LICENSE](LICENSE).
### Production Deployment

To take Veraxi live on a real domain with SSL (HTTPS):

1. **Install NGINX Ingress & Cert-Manager** in your cluster:
   ```bash
   helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
   helm install nginx-ingress ingress-nginx/ingress-nginx
   
   helm repo add jetstack https://charts.jetstack.io
   helm install cert-manager jetstack/cert-manager --set crds.enabled=true
   ```

2. **Configure your Domain:** 
   Open `helm/veraxi/values.yaml` and replace `YOUR_DOMAIN_HERE.com` with your actual domain name under the `ingress:` block.

3. **Deploy:**
   ```bash
   helm upgrade --install veraxi ./helm/veraxi
   ```
   *Cert-manager will automatically provision a Let's Encrypt SSL certificate for your domain.*
