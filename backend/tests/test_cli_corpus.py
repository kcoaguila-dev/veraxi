"""CLI tests for briefing/dbt (WP3) with mocked HTTP."""
import json
from unittest.mock import patch

import pytest
from veraxi.cli.corpus import run_briefing, run_dbt_lineage, run_dbt_upload

PATCH_TARGET = "veraxi.cli.http_client.api_request"

VALID_MANIFEST = {"nodes": {"model.proj.orders": {"name": "orders", "resource_type": "model"}}, "metadata": {}}


def test_briefing_markdown_stdout(capsys):
    with patch(PATCH_TARGET, return_value={"markdown": "# Briefing\nhello", "totals": {}}), pytest.raises(SystemExit) as exc:
        run_briefing()
    assert exc.value.code == 0
    assert "# Briefing" in capsys.readouterr().out


def test_briefing_out_file(tmp_path):
    out = tmp_path / "b.md"
    with patch(PATCH_TARGET, return_value={"markdown": "# B"}), pytest.raises(SystemExit) as exc:
        run_briefing(out=str(out))
    assert exc.value.code == 0
    assert out.read_text(encoding="utf-8") == "# B"


def test_dbt_upload_valid_payload(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(VALID_MANIFEST), encoding="utf-8")
    with patch(PATCH_TARGET, return_value={"status": "ok", "datasets": 1}) as mock, pytest.raises(SystemExit) as exc:
        run_dbt_upload(str(path))
    assert exc.value.code == 0
    args, kwargs = mock.call_args
    assert args[1] == "/api/v1/dbt/ingest"
    assert kwargs["body"] == {"manifest": VALID_MANIFEST}


def test_dbt_upload_invalid_no_nodes(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps({"metadata": {}}), encoding="utf-8")
    with patch(PATCH_TARGET) as mock, pytest.raises(SystemExit) as exc:
        run_dbt_upload(str(path))
    assert exc.value.code == 1
    mock.assert_not_called()


def test_dbt_upload_bad_json(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text("{nope", encoding="utf-8")
    with pytest.raises(SystemExit) as exc:
        run_dbt_upload(str(path))
    assert exc.value.code == 1


def test_dbt_lineage_rendering(capsys):
    ret = {"query": "orders", "matches": [{
        "name": "orders", "unique_id": "model.proj.orders", "matched_by": ["name"],
        "upstream": [{"name": "raw_orders"}], "downstream": [{"name": "revenue"}]}]}
    with patch(PATCH_TARGET, return_value=ret) as mock, pytest.raises(SystemExit) as exc:
        run_dbt_lineage("orders")
    assert exc.value.code == 0
    assert mock.call_args.kwargs["params"] == {"q": "orders"}
    out = capsys.readouterr().out
    assert "orders" in out and "upstream: raw_orders" in out and "downstream: revenue" in out
