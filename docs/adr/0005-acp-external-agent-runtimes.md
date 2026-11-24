# 5. External ACP Agent Runtimes (Google Antigravity CLI Integration)

Date: 2026-11-24

## Status

Accepted

## Context

Users with existing AI coding subscriptions (such as Google AI Pro / Ultra via Google Antigravity `agy`) want to use their subscription quota inside Veraxi's interactive Chat and Code Workbench surfaces without incurring separate API-key token charges.

However, Google Antigravity Terms of Service (Section 6) prohibit wrapping personal OAuth (`oauth-personal`) credentials in automated third-party harnesses, OAuth-scraping proxies, or outer orchestrators that inject custom system prompts, replay history, or drive automated background loops. Conversely, driving the official, unmodified local `agy acp` binary interactively via the **Agent Client Protocol (ACP)**—JSON-RPC 2.0 over `stdio`—as a thin, single-user client where Antigravity remains the primary agent is the sanctioned local integration model (used by Zed, JetBrains, and `t3code`).

## Decision

1. **Dual-Engine Split (`agent_runtime = "veraxi" | "antigravity_acp"`)**:
   - **Veraxi Managed Engine (`"veraxi"`)**: Existing LangGraph CRAG, multi-agent Deep Debate, document/code ingestion, grounding evaluation, and title generation remain on BYOK API keys, Vertex AI, or local Ollama/vLLM/GGUF models.
   - **External ACP Runtime (`"antigravity_acp"`)**: Interactive single-user Chat and Code Workbench sessions may opt into `antigravity_acp`, bypassing LangGraph and delegating the entire agent loop to the official `agy acp` subprocess.
2. **Fail-Fast Policy Guardrails**: `POST /api/chat` rejects `agent_runtime="antigravity_acp"` with HTTP 400 if combined with `mode="deep"`, `calculate_grounding=True`, or `custom_system_prompt`.
3. **Veraxi Intelligence via MCP (`/mcp`)**: Rather than injecting retrieved context into prompts, `session/new` passes Veraxi's tenant-scoped `/mcp` Streamable HTTP endpoint (with a short-lived scoped token) so Antigravity can natively invoke Veraxi's Neo4j + Qdrant GraphRAG, Code X-Ray, and Vuln Intel tools.
4. **Zero Credential Exfiltration & Scrubbed Subprocess Env**: `backend/acp/driver.py` spawns `agy acp` with an allowlisted environment (`PATH`, `HOME`, `LANG`, `LC_ALL`, `TERM`, `TMPDIR`, `XDG_*`), never exposing backend secrets (`NEO4J_PASSWORD`, `STRIPE_API_KEY`, `SUPABASE_SERVICE_KEY`). For cloud/remote Veraxi deployments, `veraxi-runner` executes `agy acp` on the user's workstation over outbound WebSocket.
5. **Zero New Mandatory Dependencies**: ACP JSON-RPC 2.0 NDJSON framing is implemented with Python stdlib (`asyncio.create_subprocess_exec`, `json`, `dataclasses`).
6. **Honest Quota Telemetry**: Because upstream ACP servers do not yet stream live quota buckets, `backend/acp/usage_reader.py` reads local conversation history best-effort and never fabricates a `100%` remaining indicator; HTTP 429 / quota-exhaustion errors surface as structured `quota_exhausted` SSE events with a one-click BYOK fallback.

## Consequences

- **Positive**: Compliant use of personal Antigravity quota in interactive sessions; zero OAuth token handling by Veraxi; clean protocol abstraction extensible to future ACP agents (Claude Code ACP, Gemini CLI ACP); zero new Python dependencies.
- **Negative**: Multi-agent Deep Debate and automated ingestion cannot use personal Antigravity OAuth quota and continue to require API keys or local models.
