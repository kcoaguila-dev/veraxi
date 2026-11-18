"""CLI tests for `veraxi memories` (WP4, Supabase user_memories) with mocked HTTP."""
import json
from unittest.mock import patch

import pytest
from veraxi.cli.memories import (
    run_memories_add,
    run_memories_delete,
    run_memories_edit,
    run_memories_expire,
    run_memories_list,
)

PATCH_TARGET = "veraxi.cli.http_client.api_request"

ROWS = [
    {"id": "m1", "content": "Likes dark mode", "source": "manual", "valid_to": None},
    {"id": "m2", "content": "Old preference", "source": "chat", "valid_to": "2026-01-01T00:00:00Z"},
]


def test_list_hides_expired_by_default(capsys):
    with patch(PATCH_TARGET, return_value={"memories": ROWS}) as mock, pytest.raises(SystemExit) as exc:
        run_memories_list()
    assert exc.value.code == 0
    assert mock.call_args.kwargs["params"] == {"include_expired": "false"}
    out = capsys.readouterr().out
    assert "Likes dark mode" in out and "Old preference" not in out


def test_list_all_shows_expired_with_valid_to(capsys):
    with patch(PATCH_TARGET, return_value={"memories": ROWS}) as mock, pytest.raises(SystemExit) as exc:
        run_memories_list(include_all=True)
    assert exc.value.code == 0
    assert mock.call_args.kwargs["params"] == {"include_expired": "true"}
    out = capsys.readouterr().out
    assert "Old preference" in out and "valid_to=2026-01-01" in out


def test_add_posts_content():
    ret = {"id": "m3", "content": "New fact", "source": "manual", "valid_to": None}
    with patch(PATCH_TARGET, return_value=ret) as mock, pytest.raises(SystemExit) as exc:
        run_memories_add("New fact")
    assert exc.value.code == 0
    args, kwargs = mock.call_args
    assert args[0] == "POST" and args[1] == "/api/v1/memories"
    assert kwargs["body"] == {"content": "New fact", "source": "manual"}


def test_edit_puts_changes():
    ret = {"id": "m1", "content": "Edited", "source": "manual", "valid_to": None}
    with patch(PATCH_TARGET, return_value=ret) as mock, pytest.raises(SystemExit) as exc:
        run_memories_edit("m1", content="Edited")
    assert exc.value.code == 0
    args, kwargs = mock.call_args
    assert args[0] == "PUT" and args[1] == "/api/v1/memories/m1"
    assert kwargs["body"] == {"content": "Edited"}


def test_expire_posts_expire_and_retains(capsys):
    ret = {"id": "m1", "content": "x", "source": "manual", "valid_to": "2026-11-18T00:00:00Z"}
    with patch(PATCH_TARGET, return_value=ret) as mock, pytest.raises(SystemExit) as exc:
        run_memories_expire("m1")
    assert exc.value.code == 0
    args, _kwargs = mock.call_args
    assert args[0] == "POST" and args[1] == "/api/v1/memories/m1/expire"
    assert "row retained" in capsys.readouterr().out


def test_delete_uses_delete_method():
    with patch(PATCH_TARGET, return_value={"status": "deleted", "id": "m1"}) as mock, pytest.raises(SystemExit) as exc:
        run_memories_delete("m1")
    assert exc.value.code == 0
    args, _kwargs = mock.call_args
    assert args[0] == "DELETE" and args[1] == "/api/v1/memories/m1"


def test_list_json(capsys):
    with patch(PATCH_TARGET, return_value={"memories": ROWS}), pytest.raises(SystemExit):
        run_memories_list(as_json=True, include_all=True)
    data = json.loads(capsys.readouterr().out)
    assert len(data["memories"]) == 2


def test_list_empty_prints_helpful_message(capsys):
    with patch(PATCH_TARGET, return_value={"memories": []}), pytest.raises(SystemExit) as exc:
        run_memories_list()
    assert exc.value.code == 0
    out = capsys.readouterr().out
    assert "No memories found." in out
    assert "veraxi memories add" in out
