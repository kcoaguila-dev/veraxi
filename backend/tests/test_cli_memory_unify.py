"""PR6 memory-unification tests: remember/memory list on user_memories SSOT."""
import json
from unittest.mock import patch

import pytest
from veraxi.cli.memory import run_memory_list, run_remember

PATCH_TARGET = "veraxi.cli.http_client.api_request"
API_RET = {"id": "m-9", "content": "Use RS256", "source": "manual",
           "valid_to": None, "created_at": "2026-11-18T00:00:00Z"}


def test_remember_posts_to_user_memories(capsys):
    with patch(PATCH_TARGET, return_value=API_RET) as mock:
        run_remember("Use RS256", as_json=True)
    data = json.loads(capsys.readouterr().out)
    assert data["storage"] == "user_memories"
    assert mock.call_args.kwargs["body"] == {"content": "Use RS256", "source": "manual"}


def test_remember_dropped_fields_warn_not_silent(capsys):
    with patch(PATCH_TARGET, return_value=API_RET):
        run_remember("Use RS256", tag="auth", memory_type="invariant",
                     supersedes="old-1", project="proj", as_json=True)
    err = capsys.readouterr().err
    for field in ("tag", "type", "supersedes", "project"):
        assert field in err


def test_remember_no_rules_json_fallback(tmp_path, monkeypatch):
    # The retired dual-write must not create .veraxi/rules.json anymore.
    monkeypatch.chdir(tmp_path)
    with patch(PATCH_TARGET, return_value=API_RET):
        run_remember("Use RS256", as_json=True)
    assert not (tmp_path / ".veraxi" / "rules.json").exists()


def test_remember_empty_exits_1():
    with pytest.raises(SystemExit) as exc:
        run_remember("   ")
    assert exc.value.code == 1


def test_memory_list_reads_user_memories(capsys):
    ret = {"memories": [{"id": "m1", "content": "Fact", "source": "chat", "valid_to": None}]}
    with patch(PATCH_TARGET, return_value=ret) as mock:
        run_memory_list(as_json=True)
    data = json.loads(capsys.readouterr().out)
    assert data[0]["content"] == "Fact"
    assert mock.call_args.args[1] == "/api/v1/memories"


def test_memory_list_project_dropped_warning(capsys):
    with patch(PATCH_TARGET, return_value={"memories": []}):
        run_memory_list(project="proj", as_json=True)
    assert "project" in capsys.readouterr().err
