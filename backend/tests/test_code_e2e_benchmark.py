"""Tests for the End-to-End Code Intelligence Benchmark (Slice 5)."""

from __future__ import annotations

from pathlib import Path

from backend.evaluation.code_e2e_benchmark import TASKS, run_code_e2e_benchmark


def test_code_e2e_benchmark_runs_on_veraxi_repo():
    repo_root = Path(__file__).resolve().parents[2]
    report = run_code_e2e_benchmark(repo_root)
    assert report["tasks"] == len(TASKS)
    assert len(TASKS) >= 10
    strategies = report["strategies"]
    assert set(strategies) == {"grep_only", "vector_ast_chunks", "veraxi_full_stack"}
    for name, metrics in strategies.items():
        assert 0.0 <= metrics["recall_at_5"] <= 1.0, name
        assert 0.0 <= metrics["symbol_correctness"] <= 1.0, name
        assert metrics["avg_latency_ms"] >= 0.0, name
        assert metrics["avg_context_tokens"] > 0, name
    # Veraxi full stack should match or beat grep-only on recall and/or symbol correctness
    assert (
        strategies["veraxi_full_stack"]["recall_at_5"]
        >= strategies["grep_only"]["recall_at_5"]
    )
    assert (
        strategies["veraxi_full_stack"]["symbol_correctness"]
        >= strategies["grep_only"]["symbol_correctness"]
    )
