"""End-to-End Retrieval & Token-Efficiency Benchmark on Veraxi's own repo (Slice 5).

Compares three retrieval strategies across 10 real multi-file architectural and
debugging tasks on ``backend/``, ``runner/``, and ``packages/``:

1. ``grep_only``: regex/ripgrep-style scan + reading matching files (top 5).
2. ``vector_ast_chunks``: identifier-aware BM25/TF-IDF ranking over AST chunks (top 5).
3. ``veraxi_full_stack``: ``parse_repo`` structural graph (``symbol_lookup`` +
   1-hop ``impact_analysis``) fused with identifier-aware AST chunks.

Measures ``recall@5``, ``symbol_correctness``, ``avg_latency_ms``, and
``avg_context_tokens`` (``len(text) // 4``). Pure and deterministic — no LLM
API keys or live DB required.
"""

from __future__ import annotations

import json
import math
import re
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from backend.ingestion.chunk_embed import chunk_code, expand_code_identifiers
from backend.ingestion.code_graph import CodeGraph, collect_parseable_files, parse_repo


@dataclass(frozen=True)
class BenchmarkTask:
    id: str
    query: str
    target_symbol: str
    expected_files: tuple[str, ...]


TASKS: tuple[BenchmarkTask, ...] = (
    BenchmarkTask(
        id="edge-counts-overview",
        query="Where is edge_counts defined and how does repo_overview use it?",
        target_symbol="edge_counts",
        expected_files=("backend/retrieval/code_queries.py",),
    ),
    BenchmarkTask(
        id="merge-rank-dispatch",
        query="Which module calls merge_rank during tool dispatch?",
        target_symbol="merge_rank",
        expected_files=("backend/retrieval/merge_rank.py", "backend/mcp_server/tool_dispatch.py"),
    ),
    BenchmarkTask(
        id="chunk-and-embed",
        query="How does chunk_and_embed produce dense and sparse vectors?",
        target_symbol="chunk_and_embed",
        expected_files=("backend/ingestion/chunk_embed.py",),
    ),
    BenchmarkTask(
        id="parse-repo-entry",
        query="Where is parse_repo implemented for building the CodeGraph?",
        target_symbol="parse_repo",
        expected_files=("backend/ingestion/code_graph.py",),
    ),
    BenchmarkTask(
        id="expand-identifiers",
        query="How does expand_code_identifiers split camelCase and snake_case tokens?",
        target_symbol="expand_code_identifiers",
        expected_files=("backend/ingestion/chunk_embed.py",),
    ),
    BenchmarkTask(
        id="ws-runner-provider",
        query="Where is WsRunnerProvider implemented and used for LSP tools?",
        target_symbol="WsRunnerProvider",
        expected_files=("backend/sandbox/ws_runner_provider.py", "backend/mcp_server/tool_dispatch.py"),
    ),
    BenchmarkTask(
        id="local-executor-confinement",
        query="How does LocalExecutor dispatch runner methods under repo confinement?",
        target_symbol="LocalExecutor",
        expected_files=("runner/veraxi_runner/local_exec.py",),
    ),
    BenchmarkTask(
        id="lsp-sidecar-manager",
        query="Where is LspSidecarManager implemented and wired into LocalExecutor?",
        target_symbol="LspSidecarManager",
        expected_files=("runner/veraxi_runner/lsp_sidecar.py", "runner/veraxi_runner/local_exec.py"),
    ),
    BenchmarkTask(
        id="execute-lsp-tool",
        query="How does execute_lsp_tool handle offline runner fallback?",
        target_symbol="execute_lsp_tool",
        expected_files=("backend/mcp_server/tool_dispatch.py",),
    ),
    BenchmarkTask(
        id="scip-cli-generate",
        query="Where is run_xray_index_generate_scip implemented and invoked in CLI?",
        target_symbol="run_xray_index_generate_scip",
        expected_files=(
            "packages/veraxi-cli/src/veraxi/cli/code_intel.py",
            "packages/veraxi-cli/src/veraxi/cli/main.py",
        ),
    ),
)

_TOKEN_RE = re.compile(r"[A-Za-z0-9_]+")


def _tokenize(text: str) -> list[str]:
    return [t.lower() for t in _TOKEN_RE.findall(expand_code_identifiers(text))]


def _build_ast_chunk_corpus(
    repo_root: Path, files: list[Path]
) -> list[tuple[str, str, Counter[str]]]:
    corpus: list[tuple[str, str, Counter[str]]] = []
    for path in files:
        if path.suffix.lower() != ".py":
            continue
        rel = path.relative_to(repo_root).as_posix()
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for chunk in chunk_code(text, rel, chunk_size=1200):
            corpus.append((rel, chunk, Counter(_tokenize(chunk))))
    return corpus


def _score_bm25_chunks(
    query: str,
    corpus: list[tuple[str, str, Counter[str]]],
    idf: dict[str, float],
    top_k: int = 5,
) -> list[tuple[str, str]]:
    q_tokens = _tokenize(query)
    scored: list[tuple[float, str, str]] = []
    for rel, chunk, tf in corpus:
        score = 0.0
        dl = sum(tf.values()) or 1
        for tok in q_tokens:
            f = tf.get(tok, 0)
            if f:
                score += idf.get(tok, 1.0) * (f * 2.5) / (f + 1.5 * (0.25 + 0.75 * dl / 120.0))
        if score > 0:
            scored.append((score, rel, chunk))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [(rel, chunk) for _, rel, chunk in scored[:top_k]]


def _run_grep_only(
    task: BenchmarkTask, repo_root: Path, files: list[Path]
) -> tuple[list[str], bool, int]:
    pat = re.compile(re.escape(task.target_symbol))
    matched_files: list[str] = []
    total_chars = 0
    for path in files:
        if path.suffix.lower() != ".py":
            continue
        try:
            content = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if pat.search(content):
            rel = path.relative_to(repo_root).as_posix()
            matched_files.append(rel)
            if len(matched_files) <= 5:
                # Grep-only loop reads the full matching file into context
                total_chars += len(content)
    top5 = matched_files[:5]
    found_sym = len(matched_files) > 0
    return top5, found_sym, max(1, total_chars // 4)


def _run_vector_ast(
    task: BenchmarkTask,
    corpus: list[tuple[str, str, Counter[str]]],
    idf: dict[str, float],
) -> tuple[list[str], bool, int]:
    hits = _score_bm25_chunks(task.query, corpus, idf, top_k=5)
    top_files = list(dict.fromkeys(rel for rel, _ in hits))[:5]
    joined = "\n".join(chunk for _, chunk in hits)
    found_sym = task.target_symbol in joined
    return top_files, found_sym, max(1, len(joined) // 4)


def _run_veraxi_full_stack(
    task: BenchmarkTask,
    graph: CodeGraph,
    corpus: list[tuple[str, str, Counter[str]]],
    idf: dict[str, float],
) -> tuple[list[str], bool, int]:
    # 1. Graph symbol lookup + 1-hop incoming callers/importers
    matching_nodes = [
        n for n in graph.nodes
        if n.name == task.target_symbol or n.qualified_name.endswith(f".{task.target_symbol}")
    ]
    target_qns = {n.qualified_name for n in matching_nodes}
    by_qn = {n.qualified_name: n for n in graph.nodes}
    graph_files: list[str] = []
    for n in matching_nodes:
        if n.path and n.path not in graph_files:
            graph_files.append(n.path)
    for edge in graph.edges:
        if edge.target_qn in target_qns and edge.type in ("CALLS", "IMPORTS", "INHERITS"):
            src = by_qn.get(edge.source_qn)
            if src and src.path and src.path not in graph_files:
                graph_files.append(src.path)

    # 2. Hybrid AST chunk retrieval
    chunk_hits = _score_bm25_chunks(task.query, corpus, idf, top_k=3)
    combined_files = list(dict.fromkeys([*graph_files, *(rel for rel, _ in chunk_hits)]))[:5]
    graph_summary = "\n".join(f"{n.qualified_name} ({n.path}:{n.line})" for n in matching_nodes[:5])
    chunk_text_joined = "\n".join(chunk for _, chunk in chunk_hits)
    total_chars = len(graph_summary) + len(chunk_text_joined)
    found_sym = bool(matching_nodes) or (task.target_symbol in chunk_text_joined)
    return combined_files, found_sym, max(1, total_chars // 4)


def run_code_e2e_benchmark(repo_root: str | Path | None = None) -> dict[str, Any]:
    """Run all 10 tasks across the 3 strategies and return aggregate metrics."""
    root = Path(repo_root or Path(__file__).resolve().parents[2]).resolve()
    py_files = [
        p for p in collect_parseable_files(root)
        if p.suffix.lower() == ".py" and "tests/" not in p.relative_to(root).as_posix()
    ]
    corpus = _build_ast_chunk_corpus(root, py_files)
    df: Counter[str] = Counter()
    for _, _, tf in corpus:
        for tok in tf:
            df[tok] += 1
    n_docs = max(1, len(corpus))
    idf = {tok: math.log((n_docs + 1) / (freq + 1)) + 1.0 for tok, freq in df.items()}
    graph = parse_repo(root)

    buckets: dict[str, list[tuple[float, bool, float, int]]] = {
        "grep_only": [],
        "vector_ast_chunks": [],
        "veraxi_full_stack": [],
    }
    for task in TASKS:
        exp = set(task.expected_files)
        for strat_name, fn in (
            ("grep_only", lambda t=task: _run_grep_only(t, root, py_files)),
            ("vector_ast_chunks", lambda t=task: _run_vector_ast(t, corpus, idf)),
            ("veraxi_full_stack", lambda t=task: _run_veraxi_full_stack(t, graph, corpus, idf)),
        ):
            t0 = time.perf_counter()
            files, sym_ok, tokens = fn()
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            recall = len(exp & set(files)) / len(exp) if exp else 1.0
            buckets[strat_name].append((recall, sym_ok, elapsed_ms, tokens))

    summary: dict[str, dict[str, Any]] = {}
    for strat_name, rows in buckets.items():
        count = len(rows)
        summary[strat_name] = {
            "recall_at_5": round(sum(r[0] for r in rows) / count, 4),
            "symbol_correctness": round(sum(1 for r in rows if r[1]) / count, 4),
            "avg_latency_ms": round(sum(r[2] for r in rows) / count, 2),
            "avg_context_tokens": round(sum(r[3] for r in rows) / count),
        }
    return {"tasks": len(TASKS), "indexed_files": len(py_files), "strategies": summary}


if __name__ == "__main__":
    print(json.dumps(run_code_e2e_benchmark(), indent=2))
