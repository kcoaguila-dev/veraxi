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

## CLI ↔ GUI Parity (Evidence-First Features)

| GUI feature | CLI command | API route |
|---|---|---|
| Evidence Evals (ablation) | `veraxi eval ablation --dataset d.json --rankings r.json` | offline `backend.evaluation`, or `--remote` → `POST /api/v1/evals/ablation` |
| Chat usage / cost / provenance + Deep pre-flight | `veraxi chat --mode deep [--dry-run] [--show-sources]`; `/sources` in the REPL | `POST /api/chat/estimate-deep`; SSE `metadata` |
| Repo X-Ray | `veraxi xray index\|symbol\|impact` | `POST /api/v1/code/ingest`, `GET /api/v1/code/symbol`, `GET /api/v1/code/impact` |
| Vuln Intel | `veraxi vuln sync`; `veraxi vuln report . --fail-on high` | `POST /api/v1/vuln/sync`, `POST /api/v1/vuln/report` |
| Corpus Briefing | `veraxi briefing [--out file.md]` | `GET /api/v1/corpus/briefing` |
| dbt Lineage | `veraxi dbt upload manifest.json`; `veraxi dbt lineage <target>` | `POST /api/v1/dbt/ingest`, `GET /api/v1/dbt/datasets` |
| User Memories | `veraxi memories list\|add\|edit\|expire\|delete` | `/api/v1/memories` CRUD + expire |

All commands accept `--json`, `--endpoint`, `--key`, `--tenant` where
applicable. Exit codes: 0 ok, 1 error, 2 gate failed (eval thresholds,
`vuln report --fail-on`).

### CI examples

```yaml
- run: veraxi eval ablation --dataset d.json --rankings r.json --min-recall 0.6
- run: veraxi vuln report . --fail-on high
```

### Memory stores — unified on `user_memories`

`veraxi memories` (Supabase `user_memories`: per-user, temporal
`valid_to`, RLS) is the single source of truth going forward. The
legacy Neo4j-backed `veraxi memory` / `veraxi remember` commands
(project-scoped agent rules) are **deprecated**; there is no data to
migrate, and there is no dual-write or bridge between the stores.

> PR6 (memory unification): `veraxi remember` and `veraxi memory list`
> now read/write `user_memories` via `/api/v1/memories`
> (`source="manual"`). Unmapped fields (tag/type/project/supersedes)
> are dropped with a stderr warning. The Neo4j write path and the
> `.veraxi/rules.json` write-fallback are retired for `remember`;
> rules.json remains the explicit export/import file format. Other
> legacy subcommands (audit/prune/stats/resolve/reopen) remain
> functional with a deprecation notice — follow-up.
