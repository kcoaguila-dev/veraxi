# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Architectural Linting**: Configured `import_lint` in `app/analysis_options.yaml` to strictly enforce clean architecture boundaries (views -> view_models -> data) in the Flutter frontend.
- **Backend Import Boundaries**: Updated `.importlinter` contracts to explicitly prevent the `ingestion` module from calling into the `retrieval` module.
- **Sentry Telemetry Audit**: Automated the injection of `sentry_sdk.capture_exception(e)` across all backend exception handlers to ensure zero swallowed errors.

### Changed
- **Storage Client Factories**: Replaced 15+ redundant instances of `Neo4jStorageClient` and `QdrantStorageClient` initialization with a unified DRY `from_config()` factory pattern.
- **Connection Pools**: Refactored `chat_repository.dart` and `control_panel_repository.dart` to reuse the centralized `ApiClient` connection pool instead of repeatedly opening new HTTP clients.
- **Riverpod Unification**: Eliminated duplicate state providers in `control_panel_view_model.dart` to maintain a single source of truth.

### Fixed
- **UI Build Tooling**: Upgraded the `app/Dockerfile` Flutter base image to `3.24.0` to resolve SDK version constraints and ensure the self-hosted premium UI builds flawlessly.
- **Missing Imports**: Fixed missing `sentry_sdk` references in `get_stats.py`.

### Added (Previous)
- **Multi-Tenant Architecture**: Implemented Python `contextvars` middleware to strictly isolate Neo4j and Qdrant queries by `tenant_id` at the HTTP connection level.
- **Server-Sent Events (SSE) Transport**: Migrated the Model Context Protocol (MCP) server from local `stdio` to a production-grade SSE HTTP transport layer.
- **MCP Triad Completion**: Exposed `veraxi://stats` and `veraxi://schema` Resources, and the `ingest_knowledge` Prompt directly through the MCP protocol.
- **LLM-as-a-Judge Evaluation**: Integrated the `deepeval` framework with a custom Gemini judge (`custom_gemini_eval.py`) to enforce the RAG Triad (Faithfulness, Precision, Relevancy) in CI/CD.
- **Compliance Automation**: Added `THIRD_PARTY_LICENSES.md` generator logic to track all backend Python and frontend Flutter open-source dependencies.
- **API Documentation**: Auto-generated comprehensive MCP tool schemas and HTTP REST endpoints into `docs/API_REFERENCE.md`.

### Changed
- **Tool Refactoring**: Updated all 13 core GraphRAG tools to dynamically consume `tenant_id` from the asynchronous execution context rather than explicit arguments.
- **Dependencies**: Bumped development dependencies in `pyproject.toml` to support the new evaluation pipeline.

### Security
- **API Gateway Lock-Down**: Enforced Bearer token authentication on the `/sse` stream to physically restrict connected Host AIs to their respective knowledge graphs.

## [0.1.0] - 2026-07-01

### Added
- Initial release of the Veraxi Sovereign Intelligence Substrate.
- Core GraphRAG pipeline (Docling parsing, chunking, embedding).
- Neo4j Knowledge Graph integration.
- Qdrant Vector Database integration.
- Flutter mobile frontend scaffold.
