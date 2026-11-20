"""CLI tests for `veraxi eval ablation` (WP1)."""
import json
from pathlib import Path

import pytest
from veraxi.cli.evals import run_eval_ablation

SEED = Path(__file__).resolve().parents[1] / "evaluation" / "seed_dataset.json"


def _write_rankings(tmp_path):
    dataset = json.loads(SEED.read_text(encoding="utf-8"))
    cases = dataset["cases"] if isinstance(dataset, dict) else dataset
    rankings = {"vector_only": {}, "hybrid_no_graph": {}, "hybrid_with_graph": {}}
    for case in cases:
        q = case["query"]
        docs = list(case["relevant_doc_ids"])
        for cfg_rankings in rankings.values():
            cfg_rankings[q] = {"ranked_doc_ids": docs, "grounding_score": 0.9}
    path = tmp_path / "rankings.json"
    path.write_text(json.dumps(rankings), encoding="utf-8")
    return path


def test_ablation_seed_dataset_per_type(tmp_path, capsys):
    rankings = _write_rankings(tmp_path)
    with pytest.raises(SystemExit) as exc:
        run_eval_ablation(dataset=str(SEED), rankings=str(rankings), k=5, as_json=True)
    assert exc.value.code == 0
    data = json.loads(capsys.readouterr().out)
    assert "configurations" in data
    for cfg in data["configurations"].values():
        assert "lookup" in cfg["by_query_type"]
        assert cfg["overall"]["recall_at_k"] == 1.0


def test_ablation_threshold_gate_exit_2(tmp_path):
    rankings = _write_rankings(tmp_path)
    with pytest.raises(SystemExit) as exc:
        run_eval_ablation(dataset=str(SEED), rankings=str(rankings), min_recall=1.1)
    assert exc.value.code == 2


def test_ablation_threshold_pass(tmp_path):
    rankings = _write_rankings(tmp_path)
    with pytest.raises(SystemExit) as exc:
        run_eval_ablation(dataset=str(SEED), rankings=str(rankings), min_recall=0.6, min_hit_rate=0.7, min_grounding=0.5)
    assert exc.value.code == 0


def test_ablation_bad_json_exit_1(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json", encoding="utf-8")
    rankings = _write_rankings(tmp_path)
    with pytest.raises(SystemExit) as exc:
        run_eval_ablation(dataset=str(bad), rankings=str(rankings))
    assert exc.value.code == 1


def test_ablation_out_markdown(tmp_path):
    rankings = _write_rankings(tmp_path)
    out = tmp_path / "report.md"
    with pytest.raises(SystemExit) as exc:
        run_eval_ablation(dataset=str(SEED), rankings=str(rankings), out_markdown=str(out))
    assert exc.value.code == 0
    text = out.read_text(encoding="utf-8")
    assert "lookup" in text and "vector_only" in text


def test_ablation_repo_root_mode(tmp_path, capsys):
    repo = tmp_path / "repo"
    (repo / "pkg").mkdir(parents=True)
    (repo / "pkg" / "core.py").write_text(
        '"""Core math helpers."""\ndef compute_magic_hash(x):\n    return x\n',
        encoding="utf-8",
    )
    (repo / "pkg" / "caller.py").write_text(
        'from pkg.core import compute_magic_hash\n\ndef run():\n    return compute_magic_hash(1)\n',
        encoding="utf-8",
    )
    ds = tmp_path / "ds.json"
    ds.write_text(
        json.dumps(
            {
                "name": "mini-code",
                "cases": [
                    {
                        "id": "m1",
                        "query_type": "multi_hop",
                        "query": "Which caller invokes compute_magic_hash?",
                        "relevant_doc_ids": ["pkg/caller.py"],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    with pytest.raises(SystemExit) as exc:
        run_eval_ablation(dataset=str(ds), repo_root=str(repo), k=5, as_json=True)
    assert exc.value.code == 0
    data = json.loads(capsys.readouterr().out)
    assert data["configurations"]["hybrid_with_graph"]["overall"]["recall_at_k"] == 1.0
