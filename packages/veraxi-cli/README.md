# Veraxi CLI (`veraxi`)

Official lightweight client CLI for [Veraxi](https://veraxi.me) — High-precision Just-In-Time GraphRAG and Multi-Agent Knowledge Engine.

## Features

- **1-Click MCP Setup**: Automatically configures Claude Desktop, Cursor, Claude Code, and Cline to connect with Veraxi MCP server over SSE.
- **MCP Doctor**: Diagnoses endpoint connectivity, authentication validity, and client config files.
- **Interactive Knowledge Chat**: Talk with your indexed books, research papers, and documents directly in terminal.
- **Structured Briefing Docs**: Generate grounded briefing docs with linked knowledge graph entities.
- **Zero Heavy Dependencies**: Pure Python standard library (< 50 KB download, installs in < 2 seconds).

## Installation

```bash
pip install veraxi
```

## Quick Start

### 1. Interactive 1-Click MCP Installation

```bash
veraxi mcp install
```
Or for a specific client:
```bash
veraxi mcp install --client claude --key vx-your_api_key
veraxi mcp install --client cursor --key vx-your_api_key
```

### 2. Run Diagnostics (`doctor`)

```bash
veraxi mcp doctor --key vx-your_api_key
```

### 3. Headless Query Runner

```bash
veraxi mcp query "revenue recognition anomalies" --key vx-your_api_key
```

Output as structured JSON for autonomous agent tool chaining:
```bash
veraxi mcp query "inventory write-offs" --key vx-your_api_key --json
```

## License

MIT License. See [LICENSE](LICENSE) for details.
