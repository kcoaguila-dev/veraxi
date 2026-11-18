"""CLI tests for chat WP5: metrics footer, provenance, Deep pre-flight."""
import json
from unittest.mock import patch

from veraxi.cli import chat as chat_cli


def _state(**kw):
    state = {"has_started_answer": False, "sources": [], "show_sources": False, "as_json": False}
    state.update(kw)
    return state


def test_metrics_footer_with_cost(capsys):
    event = {"event": "metadata", "data": {"metrics": {
        "generation_seconds": 2.5, "prompt_tokens": 100, "completion_tokens": 50,
        "total_tokens": 150, "estimated_cost_usd": 0.0123}}}
    chat_cli._render_event(event, _state())
    out = capsys.readouterr().out
    assert "prompt=100" in out and "total=150" in out and "$0.0123" in out


def test_metrics_footer_unpriced_no_usd(capsys):
    event = {"event": "metadata", "data": {"metrics": {
        "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15,
        "estimated_cost_usd": None}}}
    chat_cli._render_event(event, _state())
    out = capsys.readouterr().out
    assert "total=15" in out and "$" not in out


def test_provenance_rendering(capsys):
    sources = [{"id": "doc-1", "provenance": {
        "legs": ["vector", "graph"], "fused_score": 0.876,
        "graph_path": [{"node": "A", "relation": "CAUSES"}, {"node": "B", "relation": None}]}}]
    event = {"event": "metadata", "data": {"metrics": {}, "sources": sources}}
    chat_cli._render_event(event, _state(show_sources=True))
    out = capsys.readouterr().out
    assert "[Vector]" in out and "[Graph]" in out and "fused_score=0.876" in out
    assert "graph_path:" in out and "A" in out and "CAUSES" in out


def test_provenance_json_raw(capsys):
    sources = [{"id": "d", "provenance": {"legs": ["sparse"], "fused_score": 0.5, "graph_path": None}}]
    chat_cli.print_provenance(sources, as_json=True)
    data = json.loads(capsys.readouterr().out)
    assert data[0]["legs"] == ["sparse"]


def test_deep_estimate_format_priced_and_unpriced():
    est = {"total_tokens": {"min": 18000, "max": 42000},
           "estimated_cost_usd": {"min": 0.09, "max": 0.21}}
    assert chat_cli.format_deep_estimate(est) == "Deep mode est: 18000–42000 tokens ($0.09–$0.21)"
    est2 = {"total_tokens": {"min": 100, "max": 200}, "estimated_cost_usd": None}
    assert chat_cli.format_deep_estimate(est2) == "Deep mode est: 100–200 tokens"


def test_estimate_failure_does_not_break_chat(capsys):
    with patch("veraxi.cli.http_client.api_request", side_effect=RuntimeError("down")):
        result = chat_cli.print_deep_estimate("https://api.veraxi.me/sse", None, "default", None)
    assert result is None
    assert capsys.readouterr().out == ""


def test_estimate_http_error_silent(capsys):
    # api_request exits with SystemExit(1) on HTTP errors; fetch must swallow it.
    with patch("veraxi.cli.http_client.api_request", side_effect=SystemExit(1)):
        assert chat_cli.fetch_deep_estimate("https://x", None, "t", None) is None


def test_fake_sse_events_answer_and_footer(capsys):
    state = _state()
    chat_cli._render_event({"event": "on_chat_model_stream", "data": {"chunk": {"content": "Hello"}}}, state)
    chat_cli._render_event({"event": "metadata", "data": {"metrics": {"total_tokens": 3}}}, state)
    out = capsys.readouterr().out
    assert "Hello" in out and "total=3" in out and state["has_started_answer"] is True
