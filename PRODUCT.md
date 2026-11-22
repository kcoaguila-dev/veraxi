# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

- **Software engineers, security researchers, and technical investigators** querying large codebases, vulnerability feeds (NVD, CISA KEV, FIRST EPSS, MITRE ATT&CK), and multi-document corpora where single-hop vector similarity fails or hallucinates.
- **Knowledge workers and research analysts** (inferred from repo: Creator & Research Studio layer) synthesizing multi-hop investigations into cited reports, narrated briefings, or NLE timelines.

## Product Purpose

Veraxi is a Hybrid GraphRAG workspace and Model Context Protocol (MCP) platform that combines deterministic graph traversal (Neo4j) with dual dense + lexical vector retrieval (Qdrant MiniLM + SPLADE), fused via Reciprocal Rank Fusion (RRF) and cross-encoder reranking (`merge_rank.py`), so answers are grounded in verifiable, line-anchored and path-attributed evidence.

## Positioning

- **Provenance and citations as structural invariants, never an optional feature flag:** Every retrieved source exposes its actual contributing retrieval legs (`Vector`, `Sparse`, `Graph`), a calibrated human match tier (`High match`, `Medium match`, `Low match`), and—when a Neo4j traversal contributed—the exact entity-relation-entity path (`Node A — RELATION → Node B`).
- **Two-Tier Just-In-Time GraphRAG & Structural Code Graph:** Avoids upfront LLM graph-extraction cost traps by combining CPU-fast base ingestion (`qdrant_point_ids` ↔ `neo4j_node_ids` bidirectional linking) with on-demand causal graph weaving and AST/SCIP code graphs carrying line-anchored `file://path#L<start>-L<end>` citations and git-commit freshness stamps.

## Operating Context

- **Dual interfaces:** A feature-first Flutter web/desktop client (`app/`, deployed at `https://veraxi.me`) paired with a FastAPI/Python pipeline (`backend/`) and the `vx` developer CLI (`packages/veraxi-cli/`).
- **Bring Your Own Key (BYOK) & Sovereign Storage:** Users connect cloud providers (OpenAI, Anthropic, Google Gemini, Groq, DeepSeek) or local models (Ollama / `.gguf`) against self-hosted or cloud Neo4j and Qdrant instances.
- **Workflows:** Fast single-pass hybrid chat, Deep Research multi-agent debate with adversarial grounding verification, Repo X-Ray symbol/blast-radius analysis, Vulnerability Intelligence reachability, and the Knowledge Hub evaluation workbench.

## Capabilities and Constraints

- **Clean Architecture & Dependency Direction:**
  - Frontend (`app/lib/features/<feature>/`): `views` → `view_models` (Riverpod) → `data` → `core/mcp_client` (enforced by `import_lint`).
  - Backend (`backend/`): `mcp_server/tools` → `retrieval` → `storage`, and `ingestion` → `storage` (enforced by `import-linter`).
- **Single-Source Fusion & Honest Provenance:** `backend/retrieval/merge_rank.py` is the single place graph and vector rankings are combined (`DEFAULT_RRF_K = 60`, `CE_SIGMOID_WEIGHT = 0.012`). `backend/retrieval/provenance.py` formats only legs and paths actually recorded at retrieval time—never fabricating dense-vs-sparse splits or uncaptured graph paths.
- **Design-First UI Constraint:** Every Flutter UI change requires an up-to-date SVG visual contract in `docs/design/`.

## Brand Commitments

- **Name & Identity:** Veraxi — Sovereign Intelligence.
- **Voice & Surface Discipline:** Operate-mode restraint in application chrome; design character lives in the evidence furniture (named inline citation pills with `< 1/N >` claim-matched excerpt popovers, in-app line-anchored code citation viewer, calibrated match tiers, plain-language retrieval activity summaries, and graph path provenance). Raw RRF scores and non-null grounding telemetry stay gated behind the opt-in Metrics inspector.

## Evidence on Hand

- **First-party 4-arm code ablation (`backend/evaluation/code_ablation.py`):** 24 self-authored cases over the Veraxi codebase (MiniLM embedder, Recall@5: Vector-only `0.611` overall / `0.344` multi-hop → +Hybrid `0.670` / `0.510` → +Graph `0.854` / `0.875` → +Rerank `0.875` / `0.969`). Directional first-party benchmark; must not be presented as an external third-party benchmark.
- **Design contracts (`docs/design/*.svg`):** Authoritative SVG specifications for chat, provenance drawer, code citation viewer, token usage ring, and Knowledge Hub panels.
- **Absences not to fabricate:** No third-party customer testimonials, external SLA claims, or unmeasured benchmark numbers may be invented.

## Product Principles

1. **Show the path, never fake the proof:** Surface only the retrieval legs, traversal hops, line anchors, and freshness stamps the backend actually captured; when a metric (like grounding adherence on historical messages) was not computed, omit the tile rather than rendering dead `--` placeholders.
2. **Human tiers by default, raw telemetry on demand:** Translate internal RRF/rerank math (`0.016`) and pipeline stage names (`Planning & Discovery`) into human-readable match tiers (`High` / `Medium` / `Low match`) and plain-language activity lines (`Thought for 2.5s · Searched the web · Checked your corpus`), keeping raw scores behind the Metrics toggle.
3. **Boring chrome, distinctive evidence furniture:** Keep navigation, headers, and composers quiet and familiar; spend visual craft on citation pills, verbatim quote popovers, code line viewers, and graph provenance cards.
4. **Route automatically, configure per workspace:** Keep per-message composer controls focused on user capabilities (`Web Search`, attachments, skills, sandbox) rather than exposing database plumbing.
