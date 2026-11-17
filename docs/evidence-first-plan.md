# Evidence-First Expansion — Implementation Plan

Status: in progress (started 2026-11-18). Positioning: Veraxi as an
**evidence-first research workbench** — hybrid GraphRAG where every claim is
traceable to a chunk, a graph path, or a source. Delivery: one stacked PR per
phase, in order; merges are Kazuo's decision.

## Audited baseline (origin/main @ a82ffee, PR #145 merged)

- `retrieval/merge_rank.py`: RRF + cross-encoder reranker; the single merge
  place (AGENTS.md). `MergedResult` already carries `sources` (which legs
  hit a result) — never surfaced in the UI.
- `retrieval/just_in_time_graph.py`: lazy/JIT dossier — Qdrant hybrid search
  (MiniLM dense + SPLADE sparse), then Neo4j entity anchors.
- Grounding score exists in the orchestrator and is rendered in Flutter
  message metrics; citation chips + a sources sidebar exist. **No graph-path
  UI.**
- `backend/evaluation/`: DeepEval-based, ONE dataset (skin cancer), no
  per-query-type split, no ablation, not public.
- `services/github_sync.py` feeds repo files as TEXT chunks into ingestion.
  **No tree-sitter / AST / code graph anywhere.**
- **No** CVE/NVD code, **no** dbt/lineage code, **no** user-visible memory,
  **no** cost/budget UX.
- PR #137 (`window.veraxi.complete`) is NOT in main — out of scope here.

## Hard guardrails

- **No new dependencies** (Python or Dart). The code graph is built with the
  Python stdlib `ast` module for Python files and conservative import /
  declaration parsing for Dart/JS/TS. *Tree-sitter is a future flagged
  upgrade, explicitly NOT approved yet.*
- No paid external services. External data (NVD/KEV) via public APIs;
  HTTP mocked in tests; tests never hit the network.
- `merge_rank.py` stays the ONLY merge/ranking logic. Neo4j↔Qdrant ID
  linking preserved. Parameterized Cypher only.
- Backend dependency direction (lint-imports 4 kept / 0 broken):
  mcp_server/tools → retrieval → storage; ingestion → storage.
- Flutter: feature-first, views → view_models → data → core/mcp_client.
  New UI requires an SVG design mockup in `docs/design/` first.
- Code nodes written by the code-graph ingester have no Qdrant point: they
  are structural (AST-derived) nodes, not text chunks, so the dual-write
  rule for *chunk* ingestion does not apply; they follow `graph_write.py`
  patterns (tenant-scoped, parameterized) and link to file chunks by path
  where a chunk exists. Rationale recorded here per AGENTS.md.

## Phases (stacked, in order)

1. **feat/evidence-evals** — typed eval dataset (query_type ∈ {lookup,
   multi_hop, global}) + seed dataset; ablation runner over
   {vector_only, hybrid_no_graph, hybrid_with_graph} behind an injectable
   retriever interface (fully mocked in tests); per-type recall@k / hit-rate
   + grounding pass-through; report generator (results JSON + markdown).
   Existing DeepEval benchmark untouched.
2. **feat/evidence-provenance** — "Show me the path": merged results expose
   legs (vector/sparse/graph), fused score, and graph path in the response;
   Flutter sources sidebar gains a provenance section (SVG design first):
   leg badges + scores, indented graph-path rendering. No new deps.
3. **feat/repo-xray** — Repo X-Ray code graph: `ingestion/code_graph.py`
   parses Python (stdlib `ast`) + Dart/JS/TS (import/declaration parsing)
   into CodeFile/CodeModule/Class/Function nodes and IMPORTS/CALLS/DEFINES/
   INHERITS edges (Neo4j, tenant-scoped); `retrieval/` query layer (impact
   analysis via reverse-dependency traversal, exact symbol lookup); MCP
   tools `code_impact`, `code_symbol`, `code_overview`.
4. **feat/vuln-intel** — Vuln Intel pack: NVD JSON + CISA KEV parsers
   (fetch via httpx, mocked in tests), CVE/CWE nodes + AFFECTS/WEAKNESS
   edges; dependency extraction from pyproject.toml / pubspec.yaml /
   package.json; MCP tool `vuln_report` joining repo dependencies to CVEs
   with CWE, failing closed on unparseable versions.
5. **feat/memory-cost** — (a) User-visible temporal memory: migration 007,
   store + CRUD routes (`register_*_routes` pattern), Flutter settings UI
   (SVG first). (b) Cost UX: per-response usage (tokens; estimated cost only
   when pricing is known from models_config — never invented), Deep-mode
   pre-flight estimate endpoint, usage in the existing message metrics
   widget.
6. **feat/corpus-briefing** (only if 1–5 land) — (a) Corpus Briefing:
   deterministic briefing from graph_analytics communities + corpus stats
   (themes, newest entities, contradiction flags), markdown export, MCP
   tool. (b) Data pack: dbt manifest.json → Dataset/Model/Column nodes +
   LINEAGE edges + dataset-discovery tool.

## What NOT to build

A coding IDE / Devin clone, computer-use agent, paid sandbox fleet, eager
full-corpus GraphRAG as default, a workflow builder, enterprise SOC 2 /
HIPAA sales motion, or benchmark marketing without per-query-type
ablations and named judges.

## Status log

- Phase 1 (feat/evidence-evals): pushed as PR #146.
- Phase 2 (feat/evidence-provenance): pushed as PR #147.
- Phase 3 (feat/repo-xray): implemented + verified locally; push pending approval.
- Phase 4 (feat/vuln-intel): implemented + verified locally; push pending approval.
- Phase 5 (feat/memory-cost): implemented + verified locally; push pending approval.
- Phase 6 (feat/corpus-briefing): implemented + verified locally; push
  pending approval. Corpus Briefing lives in `retrieval/corpus_briefing.py`
  (read/query layer, reusing `graph_analytics` community detection;
  deterministic, no LLM; contradiction flags use a documented
  functional-relation heuristic, and newest entities use relationship
  `first_seen_at` as a proxy because graph nodes carry no creation
  timestamp). Data pack: `ingestion/dbt_lineage.py` (manifest parser +
  writer; sources and table/incremental-materialized models are
  `Dataset` nodes, other models/seeds/snapshots are `Model` nodes,
  tests are skipped) + `retrieval/dbt_queries.py` dataset discovery.
  MCP tools `corpus_briefing` and `dataset_discovery` registered in
  tool_dispatch, tool_schemas, tool_registry and server.
