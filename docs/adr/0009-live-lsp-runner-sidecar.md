# ADR-0009: Live LSP Sidecar in `veraxi-runner`

- **Status:** Accepted
- **Date:** 2026-11-27
- **Deciders:** Veraxi Engineering
- **Related:** [ADR-0007](0007-compiler-grade-code-intelligence.md), [ADR-0008](0008-dart-code-intelligence.md)

## Context

Per ADR-0007 and ADR-0008, compiler-grade static indexing (SCIP) provides high-precision cross-file graphs for committed/indexed snapshots, while **live LSP** (unsaved/dirty buffers, instant go-to-definition, live diagnostics, type-aware references) must **never** run inside the hosted backend container. Running arbitrary language servers (`dart`, `pyright`, `typescript-language-server`, `gopls`, `rust-analyzer`) on the hosted backend would bloat the image, require toolchain-specific SDKs (`pubspec.yaml`, `node_modules`, `go.mod`), and violate tenant isolation.

Instead, `veraxi-runner` already runs on the user's workstation or CI runner with an outbound WebSocket (`WsRunnerProvider`) and strict `resolve_under_repo` + `scrubbed_env` confinement (`runner/veraxi_runner/local_exec.py`).

## Decision

1. **LSP Manager in `veraxi-runner` (`runner/veraxi_runner/lsp_sidecar.py`):**
   - Language-agnostic `LspSidecarManager` mapping file extensions to local language server commands:
     - `.py`: `pyright-langserver --stdio`
     - `.dart`: `dart language-server --protocol=lsp`
     - `.ts`, `.tsx`, `.js`, `.jsx`: `typescript-language-server --stdio`
     - `.go`: `gopls`
     - `.rs`: `rust-analyzer`
   - Persistent subprocess pool keyed by `(repo_root, language)` with idle TTL reaping (default 600s), `Content-Length` JSON-RPC framing, `textDocument/didOpen` / `textDocument/didChange` dirty-buffer sync, and `textDocument/publishDiagnostics` caching.
   - Strict security boundaries: `resolve_under_repo` path confinement (rejecting traversal outside `--repo`) and `scrubbed_env` allowlist (no host secrets leaked to language servers).
   - **Runtime requirement:** `veraxi-runner --runtime direct` (or a Dart/Node/Go-equipped dev container image, not `python:3.12-slim`) is required for non-Python language servers to be present on `PATH`.

2. **Runner JSON-RPC & Backend `WsRunnerProvider`:**
   - Extend `LocalExecutor.handle` and `WsRunnerProvider` with four JSON-RPC methods:
     - `lsp_start(path_or_language)`
     - `lsp_request(path, method, params)` (handles `initialize`, `didOpen`/`didChange` sync, and LSP request/response)
     - `lsp_notify(path, method, params)`
     - `lsp_stop(language=None)`

3. **Read-Only MCP / Agent Tools (`backend/mcp_server/tool_dispatch.py`):**
   - Expose `lsp_definition`, `lsp_references`, and `lsp_diagnostics` when a `local_runner` is connected for the tenant (or when explicitly invoked).
   - **Fail-closed offline behavior:** When no `local_runner` is connected, tools return a structured offline response advising fallback to SCIP/Neo4j (`symbol_lookup` / `impact_analysis`) without blocking or erroring the agent loop.

## Consequences

- Zero new heavy toolchain dependencies in the hosted backend (`pyproject.toml`).
- Live IDE-grade definition, reference, and diagnostic queries work over dirty local buffers when `veraxi-runner` is connected, and degrade cleanly to SCIP/Neo4j when offline.
