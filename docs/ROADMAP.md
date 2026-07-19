# Roadmap

This project follows a **walking skeleton** approach — build the thinnest possible
end-to-end slice first, prove the riskiest connections work, then add breadth and polish.
Phases are ordered by risk, not by file-tree position or feature importance.

## Phase 0 — Scaffolding ✅ done
- [x] Repo init, `.gitignore`, `LICENSE`, `docker-compose.yml`
- [x] `.env.example` files, `config.py` reading env vars
- [x] Folder structure (backend + Flutter app)

## Phase 1 — Prove the riskiest link: ingestion + dual-write linking ✅ done
- [x] Chunk one hardcoded document, embed it, write to Qdrant
- [x] Extract entities/relations from the same document, write to Neo4j
- [x] Confirm Neo4j nodes and Qdrant points are correctly linked by ID, both directions
- [x] `test_ingestion_linking.py` — asserts every written node/point pair is actually linked
- [x] Test suite isolated via Testcontainers (ephemeral Neo4j/Qdrant, no live dev DB needed)

This was the highest-risk unknown in the whole project. It's proven — everything else
builds on this working reliably.

## Phase 2 — Retrieval and merge_rank ✅ done
- [x] `merge_rank.py` — combine and rank graph + vector results via Reciprocal Rank Fusion
- [x] `test_merge_rank.py` — fake inputs, known-correct expected output, zero DB dependency

## Phase 3 — LLM chat loop + MCP tools ✅ done
- [x] `mcp_server/tools/query_graph.py`, `search_vectors.py`
- [x] Test `merge_rank.py` against real data from Phase 1 using the new retrieval tools
- [x] `llm_loop.py` — LLM decides when to call tools, returns an answer
- [x] Replace Phase 1's regex-based `extract.py` with schema-constrained LLM extraction
      (defined entity/relation types, validated before writing to Neo4j)
- [x] `entity_resolution.py` — Splink-based deduplication, run between extraction and
      `graph_write.py`, once real extraction produces enough entity volume for
      duplicates to actually appear
- [x] Test via command line / script — no UI needed yet
- [x] `test_mcp_tools.py` — mocked DB clients, no real Neo4j/Qdrant required
- [x] `test_entity_resolution.py`

## Phase 4 — Flutter chat screen ✅ done
- [x] `features/chat` — chat_repository, chat_view_model, chat_screen
- [x] Wired to the now-working backend from Phase 3
- [x] `chat_view_model_test.dart`

## Phase 5 — Control panel ✅ done
- [x] `features/control_panel` — view graph/vector contents, trigger ingestion manually
- [x] `graph_analytics.py` — Neo4j Graph Data Science (community detection, link
      prediction) for surfacing non-obvious connections in the graph
- [x] Lower priority than chat — admin convenience, not core value
- [x] Good candidate for `good first issue` labels once open to contributors

## Phase 6 — Hardening ✅ done
- [x] CI running lint (`ruff`, `dart analyze`) + tests on every PR
- [x] `pip-audit` / `npm audit` dependency check
- [x] README polish — setup instructions, screenshot/gif of chat working
- [x] `CONTRIBUTING.md` filled in with real dev-environment setup steps

## Phase 7 — Multi-Tenant Architecture ✅ done
- [x] Implement multi-tenancy in Qdrant (payload filtering) and Neo4j (tenant_id property)
- [x] API Gateway middleware to extract tenant IDs
- [x] Update retrieval to only search within tenant bounds

## Phase 8 — Real Data Ingestion & Infrastructure Hardening ✅ done
- [x] Arbitrary document ingestion (API and Flutter UI updates)
- [x] Dockerize FastAPI backend for 1-click self-hosting
- [x] Clean up CI and documentation

## Phase 9 — Sovereign Pure MCP Architecture ✅ done
- [x] Standardize ingestion pipeline (Note: LLM extraction remains coupled to Gemini API)
- [x] Replace `RapidFuzz` with `paraphrase-multilingual-MiniLM-L12-v2` local semantic embeddings
- [x] Expose 6 refined MCP tools: `insert_graph_nodes`, `insert_vectors`, `query_graph`, `search_vectors`, `merge_rank`, and `get_graph_schema`

## Phase 10 — Cloud Run & SSE Authentication ✅ done
- [x] Refactor `server.py` from `stdio` to `SseServerTransport` (FastAPI)
- [x] Add JWT Bearer token validation middleware to FastAPI
- [x] Extract `tenant_id` securely from the JWT payload
- [x] Hardened API Gateway (Rate limiting, MIME magic bytes, Docling ingestion, Stripe Webhooks)
- [x] Ready for deployment to Google Cloud Run for zero-cost scaling

## Phase 11 — Premium Flutter UI Redesign
- [ ] Overhaul Flutter app based on `veraxi_control_ui.svg`
- [ ] Implement glassmorphism, modern typography (Inter), and dynamic color palettes
- [ ] Add micro-animations to chat interactions and node exploration

## Phase 12 — True Sovereign LLM Decoupling
- [ ] Migrate `google.genai` dependencies to `openai` Python package in `extract.py` and `llm_loop.py`
- [ ] Support local Ollama/vLLM endpoints for 100% offline sovereign ingestion

## Phase 13 — Enterprise Groundedness Evaluation ✅ done
- [x] Integrate LLM-as-a-judge logic in `backend/evaluation/grounding.py`
- [x] Expose `mcp_evaluate_grounding` tool in MCP Server
- [x] Add optional `calculate_grounding` flag to `/api/chat` endpoint

## Phase 14 — Corrective Retrieval Augmented Generation (CRAG)
- [ ] Add Retrieval Evaluator to intercept context before generation
- [ ] Implement conditional logic (Correct, Incorrect, Ambiguous)
- [ ] Build Fallback mechanisms (e.g. Web Search integration)
- [ ] Consider integrating LangGraph for agentic orchestration

---

**Currently here:** Phase 11 — Premium Flutter UI Redesign.
