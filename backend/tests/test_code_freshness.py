"""Code-index freshness: provenance stamps, disclosure, incremental update.

Covers the three parts of the freshness work in
``backend.ingestion.code_graph`` / ``backend.retrieval.code_queries``:

- Part A: ingestion stamps a ``CodeIndexMeta`` node (commit SHA +
  ``indexed_at``); a non-git repo stamps a null SHA, never a guess.
- Part B: ``symbol_lookup`` / ``impact_analysis`` / ``repo_overview``
  results carry a ``freshness`` block; ``stale`` appears only when the
  on-disk HEAD can actually be read.
- Part C: the incremental update (git diff + re-parse of changed
  files and their incoming-edge owners) produces EXACTLY the graph a
  full re-parse produces — asserted both in parse-space and against
  an in-memory model of the stored graph, across an edit set that
  modifies a body, renames a cross-file-called function, deletes a
  file and adds an (untracked) file.

The stored-graph tests run against ``ModelNeo4jClient``, a small
in-memory interpreter for the exact Cypher shapes the writer issues
(upsert node/edge, delete-by-path, orphan-placeholder cleanup, meta
reads, stored-graph loads), so the equivalence claim is checked
against the real write path, not a reimplementation of it.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from backend.ingestion.code_graph import (
    INDEX_META_LABEL,
    git_changed_paths,
    git_head_sha,
    parse_repo,
    read_index_meta,
    update_code_graph_incremental,
    update_repo_code_graph,
    write_index_meta,
    write_parsed_code_graph,
    write_repo_code_graph,
)
from backend.retrieval.code_queries import (
    impact_analysis,
    repo_overview,
    symbol_lookup,
)

TENANT = "tenant-fresh"


# ---------------------------------------------------------------------------
# In-memory model of the Neo4j write/read shapes used by code_graph.
# ---------------------------------------------------------------------------


class ModelNeo4jClient:
    """Interprets the Cypher shapes code_graph issues, in memory."""

    def __init__(self) -> None:
        self.nodes: dict[str, tuple[str, dict]] = {}
        self.edges: set[tuple[str, str, str]] = set()

    # -- writes ------------------------------------------------------
    def execute_write(self, query, parameters=None):
        params = parameters or {}
        if "MERGE (a)-[r:" in query:
            edge_type = re.search(r"\[r:([A-Z_]+)\]", query).group(1)
            self.edges.add((edge_type, params["from_key"], params["to_key"]))
            return []
        if "MERGE (n:" in query or "MERGE (m:" in query:
            label = re.search(r"MERGE \([nm]:([A-Za-z]+)", query).group(1)
            self.nodes[params["code_key"]] = (label, dict(params["properties"]))
            return []
        if "DETACH DELETE" in query:
            paths = set(params["paths"])
            doomed = {
                key
                for key, (_label, props) in self.nodes.items()
                if props.get("tenant_id") == params["tenant_id"]
                and props.get("path") in paths
                and (
                    "repo_key" not in params
                    or (props.get("repo_key") or "") == params["repo_key"]
                )
            }
            for key in doomed:
                del self.nodes[key]
            self.edges = {
                e for e in self.edges if e[1] not in doomed and e[2] not in doomed
            }
            return []
        if "DELETE n" in query:  # orphan-placeholder cleanup
            incident = {e[1] for e in self.edges} | {e[2] for e in self.edges}
            doomed = {
                key
                for key, (_label, props) in self.nodes.items()
                if props.get("tenant_id") == params["tenant_id"]
                and props.get("resolved") is False
                and (
                    "repo_key" not in params
                    or (props.get("repo_key") or "") == params["repo_key"]
                )
                and key not in incident
            }
            for key in doomed:
                del self.nodes[key]
            return []
        raise AssertionError(f"unmodelled write query: {query}")

    # -- reads -------------------------------------------------------
    def execute_read(self, query, parameters=None):
        params = parameters or {}
        if "CodeIndexMeta" in query:
            return self._meta_rows(params)
        if "AS source_qn" in query:
            return self._edge_rows(params)
        if "labels(n)[0] AS label" in query:
            return self._node_rows(params)
        raise AssertionError(f"unmodelled read query: {query}")

    def _meta_rows(self, params):
        rows = []
        for label, props in self.nodes.values():
            if label != INDEX_META_LABEL:
                continue
            if "tenant_id" in params and props.get("tenant_id") != params["tenant_id"]:
                continue
            # A None filter value means "unscoped", mirroring the
            # ($param IS NULL OR ...) shape of the real queries.
            if params.get("repo_key") is not None and props.get("repo_key") != params["repo_key"]:
                continue
            if params.get("repo_root") is not None and props.get("repo_root") != params["repo_root"]:
                continue
            rows.append(dict(props))
        rows.sort(key=lambda r: r.get("indexed_at") or "", reverse=True)
        return rows

    def _node_rows(self, params):
        rows = []
        for label, props in self.nodes.values():
            if label == INDEX_META_LABEL:
                continue
            if props.get("tenant_id") != params["tenant_id"]:
                continue
            if props.get("resolved") is False:
                continue
            if params.get("repo_key") is not None and (
                props.get("repo_key") or ""
            ) != params["repo_key"]:
                continue
            rows.append(
                {
                    "label": label,
                    "name": props.get("name"),
                    "qualified_name": props.get("qualified_name"),
                    "path": props.get("path"),
                    "line": props.get("line"),
                    "end_line": props.get("end_line"),
                    "language": props.get("language"),
                    "repo_key": props.get("repo_key") or "",
                }
            )
        return rows

    def _edge_rows(self, params):
        rows = []
        for edge_type, from_key, to_key in self.edges:
            source = self.nodes.get(from_key)
            target = self.nodes.get(to_key)
            if source is None or target is None:
                continue
            if source[1].get("tenant_id") != params["tenant_id"]:
                continue
            if params.get("repo_key") is not None and (
                (source[1].get("repo_key") or "") != params["repo_key"]
                or (target[1].get("repo_key") or "") != params["repo_key"]
            ):
                continue
            rows.append(
                {
                    "type": edge_type,
                    "source_qn": source[1].get("qualified_name"),
                    "source_label": source[0],
                    "target_qn": target[1].get("qualified_name"),
                    "target_label": target[0],
                    "repo_key": source[1].get("repo_key") or "",
                }
            )
        return rows

    def snapshot(self):
        """(nodes, edges) of the code graph, index metadata excluded."""
        nodes = {
            key: (label, tuple(sorted(props.items())))
            for key, (label, props) in self.nodes.items()
            if label != INDEX_META_LABEL
        }
        return nodes, set(self.edges)


# ---------------------------------------------------------------------------
# Fixture git repo: cross-file calls, then an edit set with a rename.
# ---------------------------------------------------------------------------

CORE_V1 = '''def helper():
    return 1


def compute():
    return helper() + 1
'''

CORE_V2 = '''def helper_v2():
    return 1


def compute():
    return helper_v2() + 2
'''

API_V1 = '''from pkg.core import compute, helper


def serve():
    return compute()


def assist():
    return helper()
'''

API_V2 = '''from pkg.core import compute, helper_v2


def serve():
    return compute()


def assist():
    return helper_v2()
'''

EXTRA_V1 = '''def temp():
    return 0
'''

MAIN_V1 = '''from pkg.api import serve
from pkg.extra import temp


def main():
    return serve() + temp()
'''

UTIL_V2 = '''def util_fn():
    return 42
'''

CHANGED_PATHS = {"pkg/core.py", "pkg/api.py", "pkg/extra.py", "pkg/util.py"}


def _write(root: Path, rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _commit(root: Path, message: str, *paths: str) -> str:
    _git(root, "add", *paths)
    _git(root, "commit", "-m", message)
    return _git(root, "rev-parse", "HEAD")


def _apply_edits(root: Path) -> None:
    """Modify a body, rename a cross-file-called function, delete a
    file, add a file (left untracked, to exercise git status)."""
    _write(root, "pkg/core.py", CORE_V2)
    _write(root, "pkg/api.py", API_V2)
    (root / "pkg" / "extra.py").unlink()
    _write(root, "pkg/util.py", UTIL_V2)


def _commit_edits(root: Path) -> str:
    return _commit(root, "v2", "pkg/core.py", "pkg/api.py", "pkg/extra.py")


@pytest.fixture()
def git_repo(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    _write(root, "pkg/__init__.py", "")
    _write(root, "pkg/core.py", CORE_V1)
    _write(root, "pkg/api.py", API_V1)
    _write(root, "pkg/extra.py", EXTRA_V1)
    _write(root, "main.py", MAIN_V1)
    _git(root, "init")
    _git(root, "config", "user.email", "t@example.com")
    _git(root, "config", "user.name", "T")
    _git(root, "add", "-A")
    _git(root, "commit", "-m", "v1")
    return root, _git(root, "rev-parse", "HEAD")


def _real(root: Path) -> str:
    return str(Path(os.path.realpath(root)))


# ---------------------------------------------------------------------------
# Part A — provenance stamps.
# ---------------------------------------------------------------------------


def test_repo_indexing_stamps_head_sha_and_timestamp(git_repo):
    root, sha1 = git_repo
    client = ModelNeo4jClient()
    write_repo_code_graph(root, tenant_id=TENANT, client=client)
    meta = read_index_meta(client, TENANT, repo_key=_real(root))
    assert meta is not None
    assert meta["source_commit"] == sha1
    assert meta["indexed_at"]
    assert meta["kind"] == "repo"
    assert meta["repo_root"] == _real(root)


def test_non_git_repo_stamps_null_commit(tmp_path):
    _write(tmp_path, "mod.py", "def f():\n    return 1\n")
    client = ModelNeo4jClient()
    write_repo_code_graph(tmp_path, tenant_id=TENANT, client=client)
    meta = read_index_meta(client, TENANT, repo_key=_real(tmp_path))
    assert meta is not None
    assert meta["source_commit"] is None
    assert meta["indexed_at"]


def test_upload_stamps_client_reported_commit():
    client = ModelNeo4jClient()
    nodes = [
        {
            "label": "Function",
            "name": "f",
            "qualified_name": "m.f",
            "path": "m.py",
            "line": 1,
        }
    ]
    write_parsed_code_graph(
        client, nodes, [], tenant_id=TENANT, repo_name="demo", source_commit="abc123"
    )
    meta = read_index_meta(client, TENANT, repo_key="demo")
    assert meta["source_commit"] == "abc123"
    assert meta["kind"] == "upload"


def test_upload_without_commit_stamps_null():
    client = ModelNeo4jClient()
    write_parsed_code_graph(client, [], [], tenant_id=TENANT, repo_name="demo")
    meta = read_index_meta(client, TENANT, repo_key="demo")
    assert meta["source_commit"] is None


# ---------------------------------------------------------------------------
# Part C — changed-path detection and the equivalence tests.
# ---------------------------------------------------------------------------


def test_git_changed_paths_covers_modify_rename_delete_untracked(git_repo):
    root, sha1 = git_repo
    _apply_edits(root)
    _commit_edits(root)
    assert git_changed_paths(root, sha1) == CHANGED_PATHS


def test_git_changed_paths_unknown_sha_returns_none(git_repo):
    root, _sha1 = git_repo
    assert git_changed_paths(root, "0" * 40) is None
    assert git_changed_paths(root, None) is None
    assert git_changed_paths(root, "") is None


def _node_sigs(graph):
    return {
        (n.label, n.qualified_name, n.path, n.line, n.end_line, n.language, n.resolved)
        for n in graph.nodes
    }


def _edge_sigs(graph):
    return {
        (e.type, e.source_qn, e.source_label, e.target_qn, e.target_label)
        for e in graph.edges
    }


def test_incremental_parse_matches_full_parse_after_edits(git_repo):
    """THE equivalence test, in parse-space.

    Index v1 fully, apply the edit set (body change + cross-file
    function rename + file delete + untracked add), run the
    incremental update, and require the resulting graph to be
    identical — node set and edge set — to a fresh full parse of the
    edited tree.
    """
    root, sha1 = git_repo
    stored = parse_repo(root)
    _apply_edits(root)
    _commit_edits(root)

    changed = git_changed_paths(root, sha1)
    assert changed == CHANGED_PATHS
    updated, reparse = update_code_graph_incremental(stored, root, changed)
    fresh = parse_repo(root)

    assert _node_sigs(updated) == _node_sigs(fresh)
    assert len(updated.nodes) == len(fresh.nodes)
    assert _edge_sigs(updated) == _edge_sigs(fresh)

    # The rename, specifically: no dangling or duplicate edges to the
    # old name, and callers in unchanged/other files point at the new
    # definition exactly as a full parse would produce.
    qns = {n.qualified_name for n in updated.nodes}
    assert "pkg.core.helper" not in qns
    assert "pkg.core.helper_v2" in qns
    assert "pkg.extra.temp" not in qns
    assert "pkg.util.util_fn" in qns
    calls = {(e.source_qn, e.target_qn) for e in updated.edges if e.type == "CALLS"}
    assert ("pkg.api.assist", "pkg.core.helper_v2") in calls
    assert ("pkg.core.compute", "pkg.core.helper_v2") in calls
    assert all(target != "pkg.core.helper" for _src, target in calls)
    # main.py owns edges into the changed api.py, so it is re-parsed
    # even though its own content did not change.
    assert "main.py" in reparse


def test_incremental_update_matches_full_reindex_in_store(git_repo):
    """The same equivalence, through the real stored write path."""
    root, sha1 = git_repo
    client = ModelNeo4jClient()
    write_repo_code_graph(root, tenant_id=TENANT, client=client)
    meta = read_index_meta(client, TENANT, repo_key=_real(root))
    assert meta["source_commit"] == sha1

    _apply_edits(root)
    sha2 = _commit_edits(root)
    result = update_repo_code_graph(root, tenant_id=TENANT, client=client)
    assert result["mode"] == "incremental"
    assert result["changed_files"] == len(CHANGED_PATHS)
    assert result["reparsed_files"] >= len(CHANGED_PATHS)
    assert result["source_commit"] == sha2

    fresh_client = ModelNeo4jClient()
    write_repo_code_graph(root, tenant_id=TENANT, client=fresh_client)
    assert client.snapshot() == fresh_client.snapshot()

    meta2 = read_index_meta(client, TENANT, repo_key=_real(root))
    assert meta2["source_commit"] == sha2
    assert meta2["indexed_at"] >= meta["indexed_at"]


def test_update_with_no_changes_is_incremental_noop(git_repo):
    root, sha1 = git_repo
    client = ModelNeo4jClient()
    write_repo_code_graph(root, tenant_id=TENANT, client=client)
    result = update_repo_code_graph(root, tenant_id=TENANT, client=client)
    assert result["mode"] == "incremental"
    assert result["changed_files"] == 0
    assert result["nodes_written"] == 0
    assert result["source_commit"] == sha1


def test_update_falls_back_to_full_without_stamp(tmp_path):
    _write(tmp_path, "mod.py", "def f():\n    return 1\n")
    client = ModelNeo4jClient()
    result = update_repo_code_graph(tmp_path, tenant_id=TENANT, client=client)
    assert result["mode"] == "full"
    assert result["nodes_written"] > 0


def test_update_falls_back_to_full_when_stamp_sha_unknown(git_repo):
    root, _sha1 = git_repo
    client = ModelNeo4jClient()
    write_repo_code_graph(root, tenant_id=TENANT, client=client)
    # Simulate a stamp whose commit is no longer in history.
    write_index_meta(
        client,
        TENANT,
        repo_key=_real(root),
        repo_root=_real(root),
        source_commit="0" * 40,
        kind="repo",
    )
    result = update_repo_code_graph(root, tenant_id=TENANT, client=client)
    assert result["mode"] == "full"


# ---------------------------------------------------------------------------
# Part B — freshness disclosure.
# ---------------------------------------------------------------------------


def _meta(root, sha, indexed_at="2026-11-21T00:00:00+00:00"):
    return {
        "repo_key": _real(root),
        "repo_root": _real(root),
        "source_commit": sha,
        "indexed_at": indexed_at,
        "kind": "repo",
    }


def test_freshness_block_fresh_then_stale_after_head_moves(git_repo):
    from backend.evaluation.code_ablation import InMemoryCodeGraphClient

    root, sha1 = git_repo
    graph = parse_repo(root)
    client = InMemoryCodeGraphClient(graph, index_meta=_meta(root, sha1))

    result = symbol_lookup("pkg.core.helper", tenant_id=TENANT, client=client)
    freshness = result["freshness"]
    assert freshness["indexed_commit"] == sha1
    assert freshness["indexed_at"] == "2026-11-21T00:00:00+00:00"
    assert freshness["current_commit"] == sha1
    assert freshness["stale"] is False

    _apply_edits(root)
    sha2 = _commit_edits(root)
    assert git_head_sha(root) == sha2

    moved = symbol_lookup("pkg.core.helper_v2", tenant_id=TENANT, client=client)
    assert moved["freshness"]["stale"] is True
    assert moved["freshness"]["current_commit"] == sha2
    assert moved["freshness"]["indexed_commit"] == sha1

    impact = impact_analysis("pkg.core.helper_v2", tenant_id=TENANT, client=client)
    assert impact["freshness"]["stale"] is True
    overview = repo_overview(tenant_id=TENANT, client=client)
    assert overview["freshness"]["indexed_commit"] == sha1


def test_freshness_block_without_meta_is_null_block(git_repo):
    from backend.evaluation.code_ablation import InMemoryCodeGraphClient

    root, _sha1 = git_repo
    client = InMemoryCodeGraphClient(parse_repo(root))
    result = repo_overview(tenant_id=TENANT, client=client)
    assert result["freshness"] == {"indexed_commit": None, "indexed_at": None}
    missing = symbol_lookup("nope", tenant_id=TENANT, client=client)
    assert missing["freshness"] == {"indexed_commit": None, "indexed_at": None}


def test_freshness_omits_stale_when_head_uncheckable(tmp_path):
    from backend.evaluation.code_ablation import InMemoryCodeGraphClient

    _write(tmp_path, "mod.py", "def f():\n    return 1\n")
    graph = parse_repo(tmp_path)
    meta = {
        "repo_key": "uploaded-graph",
        "repo_root": str(tmp_path),  # not a git checkout
        "source_commit": "abc123",
        "indexed_at": "2026-11-21T00:00:00+00:00",
        "kind": "upload",
    }
    client = InMemoryCodeGraphClient(graph, index_meta=meta)
    result = symbol_lookup("mod.f", tenant_id=TENANT, client=client)
    assert result["freshness"]["indexed_commit"] == "abc123"
    assert "stale" not in result["freshness"]
    assert "current_commit" not in result["freshness"]


# ---------------------------------------------------------------------------
# Webhook route.
# ---------------------------------------------------------------------------


def _webhook_client(monkeypatch, update_calls):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from backend.routes import code_intel as routes

    monkeypatch.setattr(routes, "_default_neo4j_client", lambda: object())
    monkeypatch.setattr(
        routes,
        "find_index_meta_for_root",
        lambda client, root: [{"tenant_id": TENANT}],
    )
    monkeypatch.setattr(
        routes, "_resolve_webhook_checkout", lambda full_name: "/srv/demo"
    )

    def fake_update(root, tenant_id=None, client=None):
        update_calls.append((root, tenant_id))
        return {"mode": "incremental", "nodes_written": 1, "edges_written": 1}

    monkeypatch.setattr(routes, "update_repo_code_graph", fake_update)
    app = FastAPI()
    routes.register_code_intel_routes(app, lambda: TENANT, lambda: None, None)
    return TestClient(app, raise_server_exceptions=False)


def _push_body(after="a" * 40):
    return json.dumps(
        {"repository": {"full_name": "acme/demo"}, "after": after}
    ).encode("utf-8")


def test_webhook_valid_signature_triggers_update(monkeypatch):
    monkeypatch.setenv("GITHUB_WEBHOOK_SECRET", "s3cret")
    calls: list = []
    client = _webhook_client(monkeypatch, calls)
    body = _push_body()
    signature = "sha256=" + hmac.new(b"s3cret", body, hashlib.sha256).hexdigest()
    response = client.post(
        "/api/v1/code/github-webhook",
        content=body,
        headers={"x-hub-signature-256": signature, "x-github-event": "push"},
    )
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert calls == [("/srv/demo", TENANT)]


def test_webhook_invalid_signature_rejected(monkeypatch):
    monkeypatch.setenv("GITHUB_WEBHOOK_SECRET", "s3cret")
    calls: list = []
    client = _webhook_client(monkeypatch, calls)
    response = client.post(
        "/api/v1/code/github-webhook",
        content=_push_body(),
        headers={"x-hub-signature-256": "sha256=" + "0" * 64, "x-github-event": "push"},
    )
    assert response.status_code == 401
    assert calls == []


def test_webhook_without_secret_accepts_and_non_push_ignored(monkeypatch):
    monkeypatch.delenv("GITHUB_WEBHOOK_SECRET", raising=False)
    calls: list = []
    client = _webhook_client(monkeypatch, calls)
    response = client.post(
        "/api/v1/code/github-webhook",
        content=_push_body(),
        headers={"x-github-event": "push"},
    )
    assert response.status_code == 200
    assert calls == [("/srv/demo", TENANT)]

    ignored = client.post(
        "/api/v1/code/github-webhook",
        content=_push_body(),
        headers={"x-github-event": "ping"},
    )
    assert ignored.status_code == 200
    assert ignored.json()["status"] == "ignored"
    assert len(calls) == 1


# ---------------------------------------------------------------------------
# CLI surface.
# ---------------------------------------------------------------------------


def test_cli_xray_index_update_posts_to_update_endpoint():
    from veraxi.cli.code_intel import run_xray_index

    ret = {
        "status": "ok",
        "repo_path": "/srv/demo",
        "mode": "incremental",
        "nodes_written": 3,
        "edges_written": 4,
    }
    with patch(
        "veraxi.cli.http_client.api_request", return_value=ret
    ) as mock, pytest.raises(SystemExit) as exc:
        run_xray_index("/srv/demo", update=True)
    assert exc.value.code == 0
    args, kwargs = mock.call_args
    assert args[0] == "POST"
    assert args[1] == "/api/v1/code/update"
    assert kwargs["body"] == {"repo_path": "/srv/demo"}


def test_cli_local_payload_carries_git_head(git_repo):
    from veraxi.cli.code_intel import parse_repo_locally

    root, sha1 = git_repo
    payload = parse_repo_locally(str(root))
    assert payload["source_commit"] == sha1


def test_cli_local_payload_non_git_commit_is_none(tmp_path):
    from veraxi.cli.code_intel import parse_repo_locally

    _write(tmp_path, "mod.py", "def f():\n    return 1\n")
    payload = parse_repo_locally(str(tmp_path))
    assert payload["source_commit"] is None
