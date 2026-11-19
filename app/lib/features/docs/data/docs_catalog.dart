/// Documentation guides, REST API contracts, and MCP tool references.
///
/// Static const catalog aligned with README.md and backend route contracts.
enum DocCategory {
  guides('GUIDES'),
  restApi('REST API'),
  mcpTools('MCP TOOLS (/sse)');

  final String label;
  const DocCategory(this.label);
}

class DocParam {
  final String name;
  final String type;
  final String description;

  const DocParam({
    required this.name,
    required this.type,
    required this.description,
  });
}

class DocEntry {
  final String id;
  final DocCategory category;
  final String title;
  final String? method;
  final String? path;
  final String summary;
  final List<String> paragraphs;
  final List<DocParam> params;
  final String? codeLabel;
  final String? codeSnippet;
  final String? responseLabel;
  final String? responseSnippet;

  const DocEntry({
    required this.id,
    required this.category,
    required this.title,
    this.method,
    this.path,
    required this.summary,
    this.paragraphs = const [],
    this.params = const [],
    this.codeLabel,
    this.codeSnippet,
    this.responseLabel,
    this.responseSnippet,
  });

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return title.toLowerCase().contains(q) ||
        summary.toLowerCase().contains(q) ||
        (path?.toLowerCase().contains(q) ?? false) ||
        (method?.toLowerCase().contains(q) ?? false);
  }
}

const List<DocEntry> kDocsCatalog = [
  // --- GUIDES ---
  DocEntry(
    id: 'quickstart',
    category: DocCategory.guides,
    title: 'Quickstart & Stack',
    summary:
        'Run the full Veraxi stack locally with Docker Compose or deploy to Kubernetes via Helm.',
    paragraphs: [
      'Veraxi combines FastAPI, Neo4j, Qdrant (MiniLM dense + SPLADE sparse vectors), Redis, SearXNG, and a cross-platform Flutter client. You can connect free cloud LLM providers (Gemini, Groq) or local models via Ollama.',
      'Once `make up` completes, open FastAPI Swagger at http://localhost:8000/docs, Neo4j Browser at http://localhost:7474, Qdrant Dashboard at http://localhost:6333/dashboard, or SearXNG at http://localhost:8080.',
    ],
    codeLabel: 'LOCAL QUICKSTART (DOCKER COMPOSE)',
    codeSnippet:
        'git clone https://github.com/kcoaguila-dev/veraxi.git\ncd veraxi\nmake setup   # copies .env templates, installs venv & pre-commit\nmake up      # starts Neo4j, Qdrant, Redis, and SearXNG\nmake seed    # seeds multi-hop test data (0 API keys needed)',
    responseLabel: 'KUBERNETES DEPLOYMENT (HELM)',
    responseSnippet:
        'helm upgrade --install veraxi ./helm/veraxi\n# Configure domain & secrets in helm/veraxi/values.yaml',
  ),
  DocEntry(
    id: 'jit-graphrag',
    category: DocCategory.guides,
    title: 'Two-Tier JIT GraphRAG',
    summary:
        'CPU-only base ingestion paired with on-demand causal graph weaving to eliminate upfront LLM token bills.',
    paragraphs: [
      'Tier 1 (CPU-Optimized): Raw PDFs, Markdown, and text files are chunked with SHA-256 pre-flight deduplication and indexed into Qdrant using MiniLM dense + SPLADE sparse embeddings. Acronym and suffix normalization links entities like "WHO" and "World Health Organization" in under 2 minutes per 500-page book with 0 GB GPU VRAM.',
      'Tier 2 (Just-In-Time Causal Weaving): When researching multi-hop questions, Veraxi retrieves ground-truth excerpts via `mcp_build_lazy_dossier`, extracts verified causal edges, and commits them via `mcp_insert_graph_nodes` with bidirectional UUID links.',
    ],
    codeLabel: 'BATCH INGESTION (CPU)',
    codeSnippet:
        'python -m backend.scripts.batch_ingest \\\n  --dir /path/to/documents \\\n  --tenant default \\\n  --fast --chunk-size 600 --chunk-overlap 100',
  ),
  DocEntry(
    id: 'vx-cli',
    category: DocCategory.guides,
    title: 'vx CLI Reference',
    summary:
        'Zero-dependency Pure Python CLI for Linux, macOS, and Android (Termux).',
    paragraphs: [
      'The `vx` developer CLI uses 100% Python standard library with zero C-extensions or glibc dependencies, installing in under 3 seconds on desktop or Termux.',
    ],
    params: [
      DocParam(
        name: 'vx chat / doctor / models',
        type: 'Core',
        description:
            'Interactive terminal assistant, MCP diagnostics, and multi-provider model switching.',
      ),
      DocParam(
        name: 'vx xray index / impact',
        type: 'Code Graph',
        description:
            'Index repositories (Tree-sitter + Python AST) and run transitive CALLS/IMPORTS blast-radius queries.',
      ),
      DocParam(
        name: 'vx vuln sync / report / sarif',
        type: 'AppSec',
        description:
            'Sync NVD, CISA KEV, EPSS, and ATT&CK feeds; scan CycloneDX/SPDX SBOMs and SARIF 2.1.0.',
      ),
      DocParam(
        name: 'vx rules sync / review',
        type: 'Governance',
        description:
            'Sync architectural invariants to CLAUDE.md, .cursorrules, and .clinerules; audit git diffs.',
      ),
    ],
    codeLabel: 'INSTALL VX CLI',
    codeSnippet:
        'curl -fsSL https://raw.githubusercontent.com/kcoaguila-dev/veraxi/main/install.sh | bash\nvx doctor',
  ),
  DocEntry(
    id: 'appsec-rules',
    category: DocCategory.guides,
    title: 'AppSec, SBOMs & Rules',
    summary:
        'Local, NDA-safe vulnerability triage combining NVD 2.0, OSV.dev, CISA KEV, EPSS, and code reachability.',
    paragraphs: [
      'Veraxi parses CycloneDX and SPDX JSON SBOMs alongside `pyproject.toml`, `uv.lock`, `package.json`, and `pubspec.yaml` with fail-closed version matching sorted by matched -> KEV -> EPSS.',
      'Ingest Semgrep, Opengrep, Trivy, or CodeQL SARIF 2.1.0 `codeFlows` taint paths and Nuclei recon findings into Neo4j (`:SecurityFinding`) and Qdrant, cross-referenced against your indexed code graph.',
    ],
    codeLabel: 'SYNC FEEDS & RUN REACHABILITY REPORT',
    codeSnippet:
        'vx vuln sync\nvx vuln attack-sync\nvx vuln report . --sbom sbom.cdx.json --reachability',
  ),

  // --- REST API ---
  DocEntry(
    id: 'api-chat',
    category: DocCategory.restApi,
    method: 'POST',
    path: '/api/chat',
    title: 'Fast & Deep Research Chat (SSE)',
    summary:
        'Streams hybrid GraphRAG responses over Server-Sent Events with inline citation chips, retrieval tool events, and optional Skeptic verification.',
    params: [
      DocParam(
        name: 'message',
        type: 'string · required',
        description: 'User query or investigation prompt.',
      ),
      DocParam(
        name: 'mode',
        type: '"fast" | "deep"',
        description:
            'Fast (<2s single loop) or Deep (LangGraph Skeptic swarm).',
      ),
      DocParam(
        name: 'tenant_id',
        type: 'string · optional',
        description: 'Tenant namespace for isolated Neo4j & Qdrant retrieval.',
      ),
    ],
    codeLabel: 'EXAMPLE REQUEST (CURL)',
    codeSnippet:
        'curl -N -X POST http://localhost:8000/api/chat \\\n  -H "Content-Type: application/json" \\\n  -d \'{"message": "Who calls verify_jwt?", "mode": "deep"}\'',
    responseLabel: 'SSE STREAM EVENTS',
    responseSnippet:
        'event: tool_event\ndata: {"tool": "mcp_merge_rank", "status": "done"}\n\nevent: token\ndata: {"text": "verify_jwt is called by login_handler [1]"}\n\ndata: {"grounding_verified": true, "unsupported_claims": 0}',
  ),
  DocEntry(
    id: 'api-ingest',
    category: DocCategory.restApi,
    method: 'POST',
    path: '/api/ingest',
    title: 'Tier 1 CPU Document Ingestion',
    summary:
        'Chunks and indexes documents into Qdrant (MiniLM dense + SPLADE sparse) with SHA-256 pre-flight deduplication and UUIDv5 chunk hashing.',
    params: [
      DocParam(
        name: 'file',
        type: 'multipart · required',
        description: 'PDF, Markdown, or plain-text document to ingest.',
      ),
      DocParam(
        name: 'replace',
        type: 'boolean · optional',
        description:
            'Purges prior chunks for the document before indexing the new edition.',
      ),
    ],
    codeLabel: 'EXAMPLE REQUEST (CURL)',
    codeSnippet:
        'curl -X POST http://localhost:8000/api/ingest \\\n  -F "file=@./docs/architecture.md" \\\n  -F "replace=true"',
    responseLabel: 'JSON RESPONSE',
    responseSnippet:
        '{\n  "status": "indexed",\n  "chunks_indexed": 48,\n  "gpu_vram_gb": 0\n}',
  ),
  DocEntry(
    id: 'api-vuln',
    category: DocCategory.restApi,
    method: 'POST',
    path: '/api/v1/vuln/report',
    title: 'SBOM & Dependency CVE Triage',
    summary:
        'Fail-closed CVE matching against NVD, OSV.dev, CISA KEV, and FIRST EPSS with optional Neo4j code-graph reachability.',
    params: [
      DocParam(
        name: 'sbom',
        type: 'object · optional',
        description: 'CycloneDX or SPDX JSON SBOM payload.',
      ),
      DocParam(
        name: 'include_reachability',
        type: 'boolean · optional',
        description:
            'Cross-reference vulnerable packages against indexed CALLS/IMPORTS edges.',
      ),
    ],
    codeLabel: 'EXAMPLE REQUEST (CURL)',
    codeSnippet:
        'curl -X POST http://localhost:8000/api/v1/vuln/report \\\n  -H "Content-Type: application/json" \\\n  -d \'{"repo_path": ".", "include_reachability": true}\'',
    responseLabel: 'JSON RESPONSE',
    responseSnippet:
        '{\n  "findings": [\n    {"cve": "CVE-2024-XXXX", "kev": true, "epss": 0.94, "reachable": true}\n  ]\n}',
  ),
  DocEntry(
    id: 'api-impact',
    category: DocCategory.restApi,
    method: 'GET',
    path: '/api/v1/code/impact',
    title: 'Codebase X-Ray Blast Radius',
    summary:
        'Queries Neo4j for transitive CALLS and IMPORTS callers of a symbol indexed by Tree-sitter or Python AST.',
    params: [
      DocParam(
        name: 'symbol',
        type: 'string · required',
        description: 'Function, class, or module symbol name.',
      ),
      DocParam(
        name: 'depth',
        type: 'integer · optional',
        description: 'Maximum traversal hops in Neo4j (default 3).',
      ),
    ],
    codeLabel: 'EXAMPLE REQUEST (CURL)',
    codeSnippet:
        'curl "http://localhost:8000/api/v1/code/impact?symbol=verify_jwt&depth=3"',
    responseLabel: 'JSON RESPONSE',
    responseSnippet:
        '{\n  "symbol": "verify_jwt",\n  "impacted": ["backend/routes/auth.py:login_handler"]\n}',
  ),

  // --- MCP TOOLS ---
  DocEntry(
    id: 'mcp-merge-rank',
    category: DocCategory.mcpTools,
    method: 'MCP',
    path: 'mcp_merge_rank',
    title: 'Primary Hybrid GraphRAG Search',
    summary:
        'Default fast (<100ms) MCP tool fusing Qdrant MiniLM dense + SPLADE sparse vectors with Neo4j multi-hop traversals via Reciprocal Rank Fusion (RRF).',
    params: [
      DocParam(
        name: 'query',
        type: 'string · required',
        description: 'Semantic search query.',
      ),
      DocParam(
        name: 'entity_name',
        type: 'string · optional',
        description: 'Optional Neo4j anchor entity for graph expansion.',
      ),
    ],
    codeLabel: 'MCP TOOL CALL',
    codeSnippet:
        'await mcp.call_tool("mcp_merge_rank", {\n  "query": "JWT token validation",\n  "entity_name": "verify_jwt"\n})',
  ),
  DocEntry(
    id: 'mcp-debate',
    category: DocCategory.mcpTools,
    method: 'MCP',
    path: 'mcp_agentic_debate',
    title: 'Multi-Agent Research Debate',
    summary:
        'Dispatches concurrent Vector, Knowledge Graph, and Web specialists, synthesizes inline citations, and runs up to 3 adversarial Skeptic grounding rounds (15–30s).',
    params: [
      DocParam(
        name: 'query',
        type: 'string · required',
        description: 'Complex multi-hop research question.',
      ),
    ],
    codeLabel: 'MCP TOOL CALL',
    codeSnippet:
        'await mcp.call_tool("mcp_agentic_debate", {\n  "query": "Trace auth blast radius across API routes"\n})',
  ),
  DocEntry(
    id: 'mcp-grounding',
    category: DocCategory.mcpTools,
    method: 'MCP',
    path: 'mcp_evaluate_grounding',
    title: 'Adversarial Skeptic Audit',
    summary:
        'Evaluates drafted claims against retrieved source passages, flagging unsupported assertions for iterative revision.',
    params: [
      DocParam(
        name: 'draft',
        type: 'string · required',
        description: 'Synthesized response text with inline citations.',
      ),
      DocParam(
        name: 'sources',
        type: 'array · required',
        description: 'Retrieved vector and graph evidence spans.',
      ),
    ],
    codeLabel: 'MCP TOOL CALL',
    codeSnippet:
        'await mcp.call_tool("mcp_evaluate_grounding", {\n  "draft": "...",\n  "sources": [...]\n})',
  ),
  DocEntry(
    id: 'mcp-dossier',
    category: DocCategory.mcpTools,
    method: 'MCP',
    path: 'mcp_build_lazy_dossier',
    title: 'Tier 2 Lazy Analytical Dossier',
    summary:
        'Retrieves ground-truth excerpts via Hybrid Search (Dense + SPLADE) fused with Neo4j entity anchors for just-in-time causal graph weaving.',
    params: [
      DocParam(
        name: 'topic',
        type: 'string · required',
        description: 'Entity or topic to weave into the knowledge graph.',
      ),
    ],
    codeLabel: 'MCP TOOL CALL',
    codeSnippet:
        'await mcp.call_tool("mcp_build_lazy_dossier", {\n  "topic": "AuthFlow"\n})',
  ),
];
