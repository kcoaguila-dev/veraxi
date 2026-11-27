"""Unit tests for the resumable RAG benchmark harness and MoE DeepEval wrapper."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from pydantic import BaseModel

from backend.evaluation.deepeval_model import (
    OpenAIDeepEvalModel,
    strip_think_and_fences,
)
from backend.evaluation.benchmark_rag import (
    aggregate_results,
    compute_retrieval_metrics,
    derive_graph_entity,
    load_jsonl_checkpoint,
    render_benchmark_markdown,
    run_generate_stage,
    run_judge_stage,
    run_retrieve_stage,
)


class _DummyJudgeSchema(BaseModel):
    score: int
    reason: str


def test_strip_think_and_fences():
    raw = "<think>\nlet me reason carefully\n</think>\n```json\n{\"score\": 5, \"reason\": \"exact\"}\n```"
    assert strip_think_and_fences(raw) == '{"score": 5, "reason": "exact"}'


def test_openai_deepeval_model_uses_judge_env_and_json_schema(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "http://localhost:8000/v1")
    monkeypatch.setenv("LLM_API_KEY", "local")
    monkeypatch.setenv("LLM_MODEL_NAME", "Qwen/Qwen3-30B-A3B-Instruct-2507-AWQ")
    monkeypatch.setenv("JUDGE_LLM_BASE_URL", "http://localhost:8001/v1")
    monkeypatch.setenv("JUDGE_LLM_API_KEY", "judge-local")
    monkeypatch.setenv("JUDGE_LLM_MODEL_NAME", "openai/gpt-oss-20b")

    from backend.config import get_config

    get_config.cache_clear()

    mock_sync_client = MagicMock()
    mock_sync_resp = MagicMock()
    mock_sync_resp.choices = [
        MagicMock(
            message=MagicMock(
                content='<think>ok</think>```json\n{"score": 4, "reason": "good"}\n```'
            )
        )
    ]
    mock_sync_client.chat.completions.create.return_value = mock_sync_resp

    mock_async_client = MagicMock()
    mock_async_client.chat.completions.create = AsyncMock(return_value=mock_sync_resp)

    with (
        patch("backend.evaluation.deepeval_model.OpenAI", return_value=mock_sync_client) as sync_cls,
        patch(
            "backend.evaluation.deepeval_model.AsyncOpenAI",
            return_value=mock_async_client,
        ) as async_cls,
    ):
        model = OpenAIDeepEvalModel()
        assert model.get_model_name() == "openai/gpt-oss-20b"
        assert sync_cls.call_args.kwargs["base_url"] == "http://localhost:8001/v1"
        assert sync_cls.call_args.kwargs["api_key"] == "judge-local"
        assert async_cls.call_args.kwargs["base_url"] == "http://localhost:8001/v1"

        parsed = model.generate("Score this", schema=_DummyJudgeSchema)
        assert isinstance(parsed, _DummyJudgeSchema)
        assert parsed.score == 4
        assert parsed.reason == "good"

        call_kwargs = mock_sync_client.chat.completions.create.call_args.kwargs
        assert call_kwargs["response_format"]["type"] == "json_schema"
        assert call_kwargs["response_format"]["json_schema"]["name"] == "_DummyJudgeSchema"


@pytest.mark.asyncio
async def test_openai_deepeval_model_async_fallback_to_json_object(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "http://localhost:8000/v1")
    monkeypatch.setenv("LLM_API_KEY", "local")
    monkeypatch.setenv("LLM_MODEL_NAME", "Qwen/Qwen3-30B-A3B-Instruct-2507-AWQ")

    from backend.config import get_config

    get_config.cache_clear()

    mock_sync_client = MagicMock()
    mock_async_client = MagicMock()

    ok_resp = MagicMock()
    ok_resp.choices = [
        MagicMock(message=MagicMock(content='{"score": 5, "reason": "fallback"}'))
    ]
    mock_async_client.chat.completions.create = AsyncMock(
        side_effect=[ValueError("json_schema unsupported"), ok_resp]
    )

    with (
        patch("backend.evaluation.deepeval_model.OpenAI", return_value=mock_sync_client),
        patch(
            "backend.evaluation.deepeval_model.AsyncOpenAI",
            return_value=mock_async_client,
        ),
    ):
        model = OpenAIDeepEvalModel()
        parsed = await model.a_generate("Score this", schema=_DummyJudgeSchema)
        assert isinstance(parsed, _DummyJudgeSchema)
        assert parsed.score == 5
        assert mock_async_client.chat.completions.create.call_count == 2
        second_kwargs = mock_async_client.chat.completions.create.call_args_list[1].kwargs
        assert second_kwargs["response_format"] == {"type": "json_object"}


def test_derive_graph_entity_never_defaults_to_basal_cell_carcinoma():
    brca_item = {
        "query": "What surveillance is recommended for a patient with a BRCA1 mutation?",
        "expected_answer": "Annual mammograms and breast MRI.",
    }
    entity = derive_graph_entity(brca_item)
    assert "basal cell carcinoma" not in entity.lower()
    assert "BRCA1" in entity

    explicit_item = {"query": "Any query", "entity": "Melanoma"}
    assert derive_graph_entity(explicit_item) == "Melanoma"


def test_compute_retrieval_metrics_recall_mrr_hit():
    contexts = [
        "First unrelated paragraph about diabetes.",
        "BRCA1 mutation increases breast cancer risk significantly.",
        "Third paragraph about hypertension.",
    ]
    evidence = ["BRCA1 mutation increases breast cancer risk significantly."]
    metrics = compute_retrieval_metrics(contexts, evidence)
    assert metrics["hit"] is True
    assert metrics["recall"] == 1.0
    assert metrics["mrr"] == pytest.approx(0.5)


def test_retrieve_generate_judge_resume_idempotency(tmp_path: Path):
    dataset = [
        {
            "id": "case-0",
            "question_type": "lookup",
            "query": "What does BRCA1 increase?",
            "expected_answer": "Breast cancer risk.",
            "evidence": ["BRCA1 increases breast cancer risk."],
        },
        {
            "id": "case-1",
            "question_type": "multi_hop",
            "query": "How does TP53 relate to Li-Fraumeni syndrome?",
            "expected_answer": "TP53 mutations cause Li-Fraumeni syndrome.",
            "evidence": ["TP53 mutations cause Li-Fraumeni syndrome."],
        },
    ]

    class _FakeHit:
        def __init__(self, hid: str, text: str, score: float = 0.9):
            self.id = hid
            self.score = score
            self.payload = {"text": text}

    seen_graph_entities: list[str] = []

    def fake_search_vectors(query_text: str, limit: int = 5, tenant_id: str = "benchmark"):
        if "BRCA1" in query_text:
            return [_FakeHit("q1", "BRCA1 increases breast cancer risk.")]
        return [_FakeHit("q2", "TP53 mutations cause Li-Fraumeni syndrome.")]

    def fake_query_graph(entity_name: str, max_hops: int = 2, tenant_id: str = "benchmark"):
        seen_graph_entities.append(entity_name)
        if "BRCA1" in entity_name:
            return [_FakeHit("g1", "BRCA1 increases breast cancer risk.")]
        return [_FakeHit("g2", "TP53 mutations cause Li-Fraumeni syndrome.")]

    ckpt_dir = tmp_path / "ckpt"
    ckpt_dir.mkdir()

    # Pre-seed case-0 in retrievals.jsonl to test --resume skips it
    pre_seeded = {
        "case_id": "case-0",
        "question_type": "lookup",
        "query": "What does BRCA1 increase?",
        "expected_answer": "Breast cancer risk.",
        "evidence": ["BRCA1 increases breast cancer risk."],
        "strategies": {
            "vector_only": {
                "contexts": ["BRCA1 increases breast cancer risk."],
                "context_text": "BRCA1 increases breast cancer risk.",
                "recall": 1.0,
                "mrr": 1.0,
                "hit": True,
                "latency_ms": 1.0,
                "context_tokens": 8,
            },
            "hybrid_with_graph": {
                "contexts": ["BRCA1 increases breast cancer risk."],
                "context_text": "BRCA1 increases breast cancer risk.",
                "recall": 1.0,
                "mrr": 1.0,
                "hit": True,
                "latency_ms": 1.5,
                "context_tokens": 8,
            },
        },
    }
    (ckpt_dir / "retrievals.jsonl").write_text(
        json.dumps(pre_seeded) + "\n", encoding="utf-8"
    )

    run_retrieve_stage(
        dataset=dataset,
        checkpoint_path=ckpt_dir / "retrievals.jsonl",
        tenant_id="benchmark",
        resume=True,
        search_vectors_fn=fake_search_vectors,
        query_graph_fn=fake_query_graph,
    )

    # Only case-1 should have triggered query_graph
    assert len(seen_graph_entities) == 1
    assert "TP53" in seen_graph_entities[0]
    assert "Basal cell carcinoma" not in seen_graph_entities[0]

    retrievals = load_jsonl_checkpoint(ckpt_dir / "retrievals.jsonl")
    assert set(retrievals.keys()) == {"case-0", "case-1"}

    async def fake_generate(query: str, context: str) -> str:
        return f"Answer based on: {context}"

    import asyncio

    asyncio.run(
        run_generate_stage(
            retrievals=retrievals,
            checkpoint_path=ckpt_dir / "answers.jsonl",
            resume=True,
            concurrency=2,
            delay_sec=0.0,
            generate_fn=fake_generate,
        )
    )

    answers = load_jsonl_checkpoint(ckpt_dir / "answers.jsonl")
    assert set(answers.keys()) == {"case-0", "case-1"}

    asyncio.run(
        run_judge_stage(
            answers=answers,
            checkpoint_path=ckpt_dir / "scores.jsonl",
            resume=True,
            concurrency=2,
            judge_mode="deterministic",
        )
    )

    scores = load_jsonl_checkpoint(ckpt_dir / "scores.jsonl")
    assert set(scores.keys()) == {"case-0", "case-1"}

    summary = aggregate_results(
        retrievals=retrievals,
        scores=scores,
        metadata={"generator_model": "test-gen", "judge_model": "deterministic"},
    )
    assert summary["total_cases"] == 2
    assert "lookup" in summary["by_question_type"]
    assert "multi_hop" in summary["by_question_type"]

    md = render_benchmark_markdown(summary)
    assert "lookup" in md
    assert "multi_hop" in md
    assert "hybrid_with_graph" in md
