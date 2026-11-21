"""Repo namespacing, webhook pull, and first-push auto-index.

Covers the three fixes stacked on the code-index freshness work:

- Fix 1 (namespacing): two repos that share a relative path AND a
  qualified symbol name, indexed into ONE tenant, stay distinct —
  in the stored graph (node identity, scoped loads), in the query
  layer (attributed matches, repo-scoped lookups, impact that never
  crosses repos), in vuln reachability, and across an incremental
  update of one repo (the other's stored subgraph is byte-identical
  before and after).
- Fix 2 (webhook pull): a push first fast-forwards the local
  checkout to the pushed commit — clean trees only, ff-only, local
  changes never discarded — and the response discloses the outcome.
- Fix 3 (auto-index): a push for a known-but-never-indexed checkout
  indexes it in full; a push with no checkout stays unresolved.

Git fixtures are entirely local (a bare repo on disk acts as the
origin); no network is touched.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest
from test_code_freshness import ModelNeo4jClient, _commit, _git, _write

from backend.ingestion.code_graph import (
    CodeEdge,
    CodeGraph,
    CodeNode,
    derive_repo_key,
    find_index_meta_for_root,
    git_pull_ff_only,
    load_stored_code_graph,
    parse_repo,
    read_index_meta,
    update_repo_code_graph,
    write_repo_code_graph,
)
from backend.retrieval.code_queries import impact_analysis, repo_overview, symbol_lookup
from backend.retrieval.vuln_queries import attach_code_reachability

TENANT = "tenant-multi"

# Repo A and repo B deliberately share the relative path pkg/core.py
# and the qualified name pkg.core.helper; bodies and definition
# lines differ so the two definitions are distinguishable.
A_CORE = '''def helper():
    return "a"


def compute():
    return helper()
'''

A_API = '''from pkg.core import helper


def assist():
    return helper()
'''

A_CORE_V2 = '''def helper_v2():
    return "a"


def compute():
    return helper_v2()
'''

A_API_V2 = '''from pkg.core import helper_v2


def assist():
    return helper_v2()
'''

B_CORE = '''# Repo B core.
# Same relative path and symbol names as repo A.


def helper():
    return "b"
'''

B_MAIN = '''from pkg.core import helper


def main():
    return helper()
'''

KEY_A = "acme/demo"
KEY_B = "acme/other"


def _real(root: Path) -> str:
    return str(Path(os.path.realpath(root)))


def _make_repo(root: Path, origin_url: str | None, files: dict[str, str]) -> str:
    root.mkdir(parents=True)
    for rel, text in files.items():
        _write(root, rel, text)
    _git(root, "init")
    _git(root, "config", "user.email", "t@example.com")
    _git(root, "config", "user.name", "T")
    if origin_url:
        _git(root, "remote", "add", "origin", origin_url)
    _git(root, "add", "-A")
    _git(root, "commit", "-m", "v1")
    return _git(root, "rev-parse", "HEAD")


@pytest.fixture()
def two_repos(tmp_path):
    root_a = tmp_path / "repo-a"
    sha_a = _make_repo(
        root_a,
        "https://github.com/acme/demo.git",
        {"pkg/__init__.py": "", "pkg/core.py": A_CORE, "pkg/api.py": A_API},
    )
    root_b = tmp_path / "repo-b"
    sha_b = _make_repo(
        root_b,
        "git@github.com:acme/other.git",
        {"pkg/__init__.py": "", "pkg/core.py": B_CORE, "main.py": B_MAIN},
    )
    return (root_a, sha_a), (root_b, sha_b)


def _merged_client(root_a: Path, root_b: Path):
    from backend.evaluation.code_ablation import InMemoryCodeGraphClient

    graph_a = parse_repo(root_a)
    graph_b = parse_repo(root_b)
    merged = CodeGraph(
        nodes=graph_a.nodes + graph_b.nodes, edges=graph_a.edges + graph_b.edges
    )
    return InMemoryCodeGraphClient(merged)


# ---------------------------------------------------------------------------
# Fix 1 — derivation.
# ---------------------------------------------------------------------------


def test_derive_repo_key_prefers_origin_slug(two_repos):
    (root_a, _), (root_b, _) = two_repos
    assert derive_repo_key(root_a) == KEY_A
    assert derive_repo_key(root_b) == KEY_B


def test_derive_repo_key_falls_back_to_repo_root(tmp_path):
    root = tmp_path / "plain"
    _make_repo(root, None, {"mod.py": "def f():\n    return 1\n"})
    assert derive_repo_key(root) == _real(root)


# ---------------------------------------------------------------------------
# Fix 1 — stored-graph isolation.
# ---------------------------------------------------------------------------


def test_two_repos_one_tenant_stay_distinct_in_store(two_repos):
    (root_a, _), (root_b, _) = two_repos
    client = ModelNeo4jClient()
    write_repo_code_graph(root_a, tenant_id=TENANT, client=client)
    write_repo_code_graph(root_b, tenant_id=TENANT, client=client)

    # Same (label, qualified name) — two distinct stored nodes.
    helper_keys = [
        key
        for key, (label, props) in client.nodes.items()
        if label == "Function" and props.get("qualified_name") == "pkg.core.helper"
    ]
    assert len(helper_keys) == 2
    assert len(set(helper_keys)) == 2

    # One stamp per repo, keyed by slug, rooted at its own checkout.
    meta_a = read_index_meta(client, TENANT, repo_key=KEY_A)
    meta_b = read_index_meta(client, TENANT, repo_key=KEY_B)
    assert meta_a["repo_root"] == _real(root_a)
    assert meta_b["repo_root"] == _real(root_b)

    # Scoped loads return each repo's own definition of the symbol.
    graph_a = load_stored_code_graph(client, TENANT, repo_key=KEY_A)
    graph_b = load_stored_code_graph(client, TENANT, repo_key=KEY_B)
    helper_a = [n for n in graph_a.nodes if n.qualified_name == "pkg.core.helper"]
    helper_b = [n for n in graph_b.nodes if n.qualified_name == "pkg.core.helper"]
    assert len(helper_a) == 1 and helper_a[0].line == 1
    assert helper_a[0].repo_key == KEY_A
    assert len(helper_b) == 1 and helper_b[0].line == 5
    assert helper_b[0].repo_key == KEY_B

    # The scoped loads partition the tenant's whole graph.
    whole = load_stored_code_graph(client, TENANT)
    assert len(graph_a.nodes) + len(graph_b.nodes) == len(whole.nodes)
    assert len(graph_a.edges) + len(graph_b.edges) == len(whole.edges)


def _repo_snapshot(client: ModelNeo4jClient, repo_key: str):
    nodes, edges = client.snapshot()
    repo_nodes = {
        key: value
        for key, value in nodes.items()
        if dict(value[1]).get("repo_key") == repo_key
    }
    repo_edges = {
        edge for edge in edges if edge[1] in repo_nodes and edge[2] in repo_nodes
    }
    return repo_nodes, repo_edges


def test_incremental_update_of_one_repo_leaves_other_byte_identical(two_repos):
    (root_a, _), (root_b, sha_b) = two_repos
    client = ModelNeo4jClient()
    write_repo_code_graph(root_a, tenant_id=TENANT, client=client)
    write_repo_code_graph(root_b, tenant_id=TENANT, client=client)
    before = _repo_snapshot(client, KEY_B)

    # Rename repo A's helper (a cross-file rename: api.py calls it).
    _write(root_a, "pkg/core.py", A_CORE_V2)
    _write(root_a, "pkg/api.py", A_API_V2)
    _commit(root_a, "v2", "pkg/core.py", "pkg/api.py")
    result = update_repo_code_graph(root_a, tenant_id=TENANT, client=client)
    assert result["mode"] == "incremental"
    assert result["repo_key"] == KEY_A

    # Repo B's stored subgraph and stamp are untouched.
    assert _repo_snapshot(client, KEY_B) == before
    meta_b = read_index_meta(client, TENANT, repo_key=KEY_B)
    assert meta_b["source_commit"] == sha_b

    # Repo A really did update.
    graph_a = load_stored_code_graph(client, TENANT, repo_key=KEY_A)
    qns = {node.qualified_name for node in graph_a.nodes}
    assert "pkg.core.helper" not in qns
    assert "pkg.core.helper_v2" in qns


# ---------------------------------------------------------------------------
# Fix 1 — query-layer scoping and disambiguation.
# ---------------------------------------------------------------------------


def test_symbol_lookup_disambiguates_across_repos(two_repos):
    (root_a, _), (root_b, _) = two_repos
    client = _merged_client(root_a, root_b)

    result = symbol_lookup("pkg.core.helper", tenant_id=TENANT, client=client)
    assert result["match_type"] == "qualified_name"
    by_repo = {match["repo_key"]: match for match in result["matches"]}
    assert set(by_repo) == {KEY_A, KEY_B}
    assert by_repo[KEY_A]["line"] == 1
    assert by_repo[KEY_B]["line"] == 5
    # The merge is disclosed, not silent.
    assert result["repos"] == [KEY_A, KEY_B]
    assert "note" in result

    scoped = symbol_lookup(
        "pkg.core.helper", tenant_id=TENANT, client=client, repo=KEY_B
    )
    assert len(scoped["matches"]) == 1
    assert scoped["matches"][0]["line"] == 5
    assert "repos" not in scoped


def test_impact_analysis_never_crosses_repos(two_repos):
    (root_a, _), (root_b, _) = two_repos
    client = _merged_client(root_a, root_b)

    result = impact_analysis("pkg.core.helper", tenant_id=TENANT, client=client)
    assert result["found"] is True
    assert result["repos"] == [KEY_A, KEY_B]
    pairs = {
        (entry.get("repo_key"), entry["qualified_name"])
        for entry in result["impacted"]
    }
    assert (KEY_A, "pkg.api.assist") in pairs
    assert (KEY_A, "pkg.core.compute") in pairs
    assert (KEY_B, "main.main") in pairs
    # No caller is ever attributed to the other repo's definition.
    assert (KEY_A, "main.main") not in pairs
    assert (KEY_B, "pkg.api.assist") not in pairs
    assert (KEY_B, "pkg.core.compute") not in pairs

    scoped = impact_analysis(
        "pkg.core.helper", tenant_id=TENANT, client=client, repo=KEY_B
    )
    assert {entry["qualified_name"] for entry in scoped["impacted"]} == {"main.main"}
    assert "repos" not in scoped


def test_single_repo_results_have_no_disambiguation_noise(two_repos):
    (root_a, _), _ = two_repos
    from backend.evaluation.code_ablation import InMemoryCodeGraphClient

    client = InMemoryCodeGraphClient(parse_repo(root_a))
    lookup = symbol_lookup("pkg.core.helper", tenant_id=TENANT, client=client)
    assert "repos" not in lookup and "note" not in lookup
    impact = impact_analysis("pkg.core.helper", tenant_id=TENANT, client=client)
    assert "repos" not in impact
    overview = repo_overview(tenant_id=TENANT, client=client)
    assert "repos" not in overview
    scoped = repo_overview(tenant_id=TENANT, client=client, repo=KEY_A)
    assert scoped["total_nodes"] == overview["total_nodes"]
    assert scoped["total_edges"] == overview["total_edges"]


def test_vuln_reachability_attributes_and_scopes_by_repo():
    def module(qn: str, name: str, path: str, repo_key: str) -> CodeNode:
        return CodeNode(
            label="CodeModule",
            name=name,
            qualified_name=qn,
            path=path,
            line=1,
            language="python",
            repo_key=repo_key,
        )

    nodes = [
        module("requests", "requests", "", KEY_A),
        module("pkg.api", "api", "pkg/api.py", KEY_A),
        module("requests", "requests", "", KEY_B),
        module("app.api", "api", "app/api.py", KEY_B),
    ]
    edges = [
        CodeEdge(
            type="IMPORTS",
            source_qn="pkg.api",
            source_label="CodeModule",
            target_qn="requests",
            target_label="CodeModule",
            repo_key=KEY_A,
        ),
        CodeEdge(
            type="IMPORTS",
            source_qn="app.api",
            source_label="CodeModule",
            target_qn="requests",
            target_label="CodeModule",
            repo_key=KEY_B,
        ),
    ]
    from backend.evaluation.code_ablation import InMemoryCodeGraphClient

    client = InMemoryCodeGraphClient(CodeGraph(nodes=nodes, edges=edges))

    findings = [{"package": "requests"}]
    attach_code_reachability(findings, tenant_id=TENANT, code_client=client)
    # The same symbol reached in two repos counts for both repos —
    # hits are attributed, not deduplicated into one.
    assert findings[0]["reachable_file_count"] == 2
    assert {hit["repo_key"] for hit in findings[0]["reachable_in_code"]} == {
        KEY_A,
        KEY_B,
    }

    scoped = [{"package": "requests"}]
    attach_code_reachability(
        scoped, tenant_id=TENANT, code_client=client, repo=KEY_A
    )
    assert scoped[0]["reachable_file_count"] == 1
    assert scoped[0]["reachable_in_code"][0]["path"] == "pkg/api.py"


# ---------------------------------------------------------------------------
# Fixes 2 + 3 — webhook pull and auto-index, on local git fixtures.
# ---------------------------------------------------------------------------


@pytest.fixture()
def remote_repo(tmp_path):
    """A bare origin, a seed clone that pushes to it, and a checkout."""
    origin = tmp_path / "origin.git"
    subprocess.run(
        ["git", "init", "--bare", "-b", "main", str(origin)],
        check=True,
        capture_output=True,
    )
    seed = tmp_path / "seed"
    seed.mkdir()
    _write(seed, "pkg/__init__.py", "")
    _write(seed, "pkg/core.py", A_CORE)
    _git(seed, "init", "-b", "main")
    _git(seed, "config", "user.email", "t@example.com")
    _git(seed, "config", "user.name", "T")
    _git(seed, "add", "-A")
    _git(seed, "commit", "-m", "v1")
    _git(seed, "remote", "add", "origin", str(origin))
    _git(seed, "push", "origin", "HEAD")
    sha1 = _git(seed, "rev-parse", "HEAD")

    roots = tmp_path / "roots"
    roots.mkdir()
    checkout = roots / "demo"
    subprocess.run(
        ["git", "clone", str(origin), str(checkout)],
        check=True,
        capture_output=True,
    )
    # Clones do not inherit the seed's local identity config.
    _git(checkout, "config", "user.email", "t@example.com")
    _git(checkout, "config", "user.name", "T")
    return {"seed": seed, "roots": roots, "checkout": checkout, "sha1": sha1}


def _advance_origin(remote) -> str:
    _write(remote["seed"], "pkg/core.py", A_CORE_V2)
    sha2 = _commit(remote["seed"], "v2", "pkg/core.py")
    _git(remote["seed"], "push", "origin", "HEAD")
    return sha2


def _route_client(monkeypatch, model, roots):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from backend.routes import code_intel as routes

    monkeypatch.setattr(routes, "_default_neo4j_client", lambda: model)
    monkeypatch.setattr(routes, "_allowed_roots", lambda: [str(roots)])
    monkeypatch.delenv("GITHUB_WEBHOOK_SECRET", raising=False)
    app = FastAPI()
    routes.register_code_intel_routes(app, lambda: TENANT, lambda: None, None)
    return TestClient(app, raise_server_exceptions=False)


def _push(client, after: str, full_name: str = "acme/demo"):
    body = json.dumps(
        {"repository": {"full_name": full_name}, "after": after}
    ).encode("utf-8")
    return client.post(
        "/api/v1/code/github-webhook",
        content=body,
        headers={"x-github-event": "push"},
    )


def test_webhook_pulls_fast_forward_then_updates(remote_repo, monkeypatch):
    model = ModelNeo4jClient()
    write_repo_code_graph(
        remote_repo["checkout"], tenant_id=TENANT, client=model
    )
    sha2 = _advance_origin(remote_repo)

    client = _route_client(monkeypatch, model, remote_repo["roots"])
    response = _push(client, sha2)
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["pull"]["pulled"] is True
    assert body["pull"]["head"] == sha2
    assert _git(remote_repo["checkout"], "rev-parse", "HEAD") == sha2
    assert body["updates"][TENANT]["source_commit"] == sha2


def test_webhook_dirty_tree_skips_pull_and_preserves_changes(
    remote_repo, monkeypatch
):
    model = ModelNeo4jClient()
    write_repo_code_graph(
        remote_repo["checkout"], tenant_id=TENANT, client=model
    )
    sha2 = _advance_origin(remote_repo)

    core = remote_repo["checkout"] / "pkg" / "core.py"
    core.write_text(core.read_text(encoding="utf-8") + "\n# local edit\n")

    client = _route_client(monkeypatch, model, remote_repo["roots"])
    response = _push(client, sha2)
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["pull"]["pulled"] is False
    assert "dirty" in body["pull"]["reason"]
    # The checkout was not moved and the local edit was not discarded.
    assert _git(remote_repo["checkout"], "rev-parse", "HEAD") == remote_repo["sha1"]
    assert "# local edit" in core.read_text(encoding="utf-8")
    # The update still ran, against the local HEAD.
    assert body["updates"][TENANT]["source_commit"] == remote_repo["sha1"]


def test_webhook_first_push_auto_indexes_checkout(remote_repo, monkeypatch):
    model = ModelNeo4jClient()
    client = _route_client(monkeypatch, model, remote_repo["roots"])
    response = _push(client, remote_repo["sha1"])
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "indexed"
    assert body["pull"]["pulled"] is False  # already at the pushed commit
    assert body["indexed"]["tenant_id"] == "default"
    assert body["indexed"]["nodes_written"] > 0
    assert body["indexed"]["repo_key"] == derive_repo_key(remote_repo["checkout"])

    metas = find_index_meta_for_root(model, _real(remote_repo["checkout"]))
    assert len(metas) == 1
    assert metas[0]["tenant_id"] == "default"
    assert metas[0]["source_commit"] == remote_repo["sha1"]


def test_webhook_without_checkout_stays_unresolved(tmp_path, monkeypatch):
    roots = tmp_path / "empty-roots"
    roots.mkdir()
    model = ModelNeo4jClient()
    client = _route_client(monkeypatch, model, roots)
    response = _push(client, "a" * 40)
    assert response.status_code == 202
    assert response.json()["status"] == "unresolved"
    assert model.nodes == {}


def test_pull_skips_non_fast_forward(remote_repo):
    checkout = remote_repo["checkout"]
    _write(checkout, "pkg/core.py", 'def local_only():\n    return "local"\n')
    local_sha = _commit(checkout, "local divergence", "pkg/core.py")
    sha2 = _advance_origin(remote_repo)

    result = git_pull_ff_only(checkout, sha2)
    assert result["pulled"] is False
    assert result["reason"] == "not a fast-forward"
    assert result["head"] == local_sha
    assert _git(checkout, "rev-parse", "HEAD") == local_sha
