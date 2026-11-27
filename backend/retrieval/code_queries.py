"""Repo X-Ray query layer over the structural code graph.

Queries run against an injectable :class:`CodeGraphClient` protocol so
tests can substitute an in-memory fake; the production implementation
is :class:`Neo4jCodeGraphClient`, which adapts the existing Neo4j
storage client and issues parameterized Cypher only (labels are
interpolated solely from the fixed code-node label list).

Traversal logic (impact analysis) lives here, not in Cypher: the
client exposes one-hop reverse-neighbour lookups and this module walks
them breadth-first up to ``max_depth``. That keeps the traversal
identical against the real adapter and any test fake.
"""

from __future__ import annotations

import logging
import subprocess
from typing import Any, Protocol, runtime_checkable

logger = logging.getLogger(__name__)

CODE_NODE_LABELS = ("CodeFile", "CodeModule", "Class", "Function")
IMPACT_EDGE_TYPES = ("CALLS", "IMPORTS", "REFERENCES")
MAX_IMPACT_DEPTH = 10


def code_source_url(path: Any, line: Any = None, end_line: Any = None) -> str | None:
    """Build the citable ``file://`` URL for one code hit.

    This is the single place code-hit citation URLs are formatted, so
    every consumer (chat tools, REST routes, CLI) cites identically.
    The anchor uses only line data the graph actually stored: a full
    ``#L<start>-L<end>`` range when an end line is known, a bare
    ``#L<start>`` when only the declaration line is known, and no
    anchor at all when no line is known. Lines are never invented —
    a hit without a path yields ``None`` (no citation target).
    """
    if not isinstance(path, str) or not path.strip():
        return None
    url = f"file://{path.strip()}"
    start = line if isinstance(line, int) and line > 0 else None
    if start is None:
        return url
    end = end_line if isinstance(end_line, int) and end_line > start else None
    if end is not None:
        return f"{url}#L{start}-L{end}"
    return f"{url}#L{start}"


def _attach_url(row: dict[str, Any]) -> dict[str, Any]:
    """Add the citable ``url`` to one code-hit row, in place."""
    url = code_source_url(row.get("path"), row.get("line"), row.get("end_line"))
    if url is not None:
        row["url"] = url
    return row


@runtime_checkable
class CodeGraphClient(Protocol):
    """Injectable graph-client interface for code-graph queries.

    Every method takes an optional ``repo_key``: when given, results
    are scoped to that one repo of the tenant's graph; when None,
    they span every repo the tenant has indexed. Node rows carry the
    node's ``repo_key`` (empty for graphs ingested before repo
    namespacing), so callers can attribute cross-repo results
    instead of silently merging them.
    """

    def find_symbols(
        self,
        tenant_id: str,
        *,
        qualified_name: str | None = None,
        name: str | None = None,
        repo_key: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return code nodes matching a qualified name or a simple name."""
        ...

    def find_file(
        self, tenant_id: str, path: str, repo_key: str | None = None
    ) -> dict[str, Any] | None:
        """Return the CodeFile row for ``path`` under ``tenant_id``.

        The row carries ``path``, ``language``, and ``repo_key``. ``None``
        means the tenant's code graph holds no file at that path — the
        tenant-scoping check for serving code file content.
        """
        ...

    def list_files(
        self,
        tenant_id: str,
        repo_key: str | None = None,
        q: str | None = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        """Return CodeFile rows for the tenant, optionally repo-scoped.

        ``q`` is a case-insensitive substring matched against the
        file's path and name. Rows carry ``path``, ``name``,
        ``language`` and ``repo_key``.
        """
        ...

    def incoming_edges(
        self, tenant_id: str, target_qns: list[str], repo_key: str | None = None
    ) -> list[dict[str, Any]]:
        """Return CALLS/IMPORTS edges pointing INTO any of ``target_qns``.

        Each row: ``source_qn``, ``source_name``, ``source_label``,
        ``source_path``, ``source_line``, ``source_end_line``,
        ``source_repo_key``, ``source_resolution``, ``edge_type``
        and ``target_qn``. The line fields mirror the source node's
        stored ``line``/``end_line`` and may be missing on clients
        backed by graphs ingested before they existed.
        ``source_resolution`` is the source node's ADR-0007
        provenance (``scip`` / ``heuristic``) and may likewise be
        missing on older clients.
        """
        ...

    def node_counts(
        self,
        tenant_id: str,
        path_prefix: str | None = None,
        repo_key: str | None = None,
    ) -> dict[str, int]:
        """Return code-node counts keyed by label."""
        ...

    def edge_counts(
        self,
        tenant_id: str,
        path_prefix: str | None = None,
        repo_key: str | None = None,
    ) -> dict[str, int]:
        """Return code-edge counts keyed by relationship type."""
        ...

    def top_connected(
        self,
        tenant_id: str,
        path_prefix: str | None = None,
        limit: int = 10,
        repo_key: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return the most-connected code nodes for the tenant."""
        ...

    def index_meta(
        self, tenant_id: str, repo_key: str | None = None
    ) -> dict[str, Any] | None:
        """Return the tenant's latest index-provenance stamp, or None.

        The stamp (written at ingestion time by
        ``backend.ingestion.code_graph.write_index_meta``) carries
        ``repo_key``, ``repo_root``, ``source_commit``, ``indexed_at``
        and ``kind``. With ``repo_key`` given, that repo's stamp.
        None means the graph predates index metadata — provenance is
        unknown, not zero.
        """
        ...

    def index_metas(self, tenant_id: str) -> list[dict[str, Any]]:
        """Return all of the tenant's index-provenance stamps.

        One stamp per indexed repo, most recent first. Used to
        disclose which repos a tenant-wide (unscoped) result spans.
        """
        ...


class Neo4jCodeGraphClient:
    """Production :class:`CodeGraphClient` over ``Neo4jStorageClient``.

    All user input travels as query parameters; the only interpolated
    values are the fixed label list above and validated integers.
    """

    def __init__(self, neo4j_client: Any = None) -> None:
        if neo4j_client is None:
            from backend.config import get_config
            from backend.storage.neo4j_client import Neo4jStorageClient

            neo4j_client = Neo4jStorageClient.from_config(get_config())
        self._client = neo4j_client

    def _read(self, query: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        return self._client.execute_read(query, params)

    def find_symbols(
        self,
        tenant_id: str,
        *,
        qualified_name: str | None = None,
        name: str | None = None,
        repo_key: str | None = None,
    ) -> list[dict[str, Any]]:
        if qualified_name is not None:
            where = "n.qualified_name = $qualified_name"
            params: dict[str, Any] = {
                "tenant_id": tenant_id,
                "qualified_name": qualified_name,
                "repo_key": repo_key,
            }
        else:
            where = "n.name = $name"
            params = {"tenant_id": tenant_id, "name": name, "repo_key": repo_key}
        query = f"""
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
          AND ($repo_key IS NULL OR coalesce(n.repo_key, '') = $repo_key)
          AND {where}
        RETURN labels(n)[0] AS label, n.name AS name,
               n.qualified_name AS qualified_name, n.path AS path,
               n.line AS line, n.end_line AS end_line, n.language AS language,
               coalesce(n.resolved, true) AS resolved,
               coalesce(n.repo_key, '') AS repo_key,
               coalesce(n.resolution, 'heuristic') AS resolution
        ORDER BY qualified_name
        """
        return self._read(query, params)

    def find_file(
        self, tenant_id: str, path: str, repo_key: str | None = None
    ) -> dict[str, Any] | None:
        query = """
        MATCH (n:CodeFile)
        WHERE n.tenant_id = $tenant_id
          AND n.path = $path
          AND ($repo_key IS NULL OR coalesce(n.repo_key, '') = $repo_key)
        RETURN n.path AS path, n.language AS language,
               coalesce(n.repo_key, '') AS repo_key
        LIMIT 1
        """
        rows = self._read(
            query, {"tenant_id": tenant_id, "path": path, "repo_key": repo_key}
        )
        return rows[0] if rows else None

    def list_files(
        self,
        tenant_id: str,
        repo_key: str | None = None,
        q: str | None = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        # All user input travels as parameters ($tenant_id, $repo_key,
        # $q, $limit); nothing is concatenated into the Cypher.
        limit = min(max(1, int(limit)), 200)
        query = """
        MATCH (n:CodeFile)
        WHERE n.tenant_id = $tenant_id
          AND ($repo_key IS NULL OR coalesce(n.repo_key, '') = $repo_key)
          AND ($q IS NULL OR toLower(n.path) CONTAINS $q
               OR toLower(coalesce(n.name, '')) CONTAINS $q)
        RETURN n.path AS path, n.name AS name, n.language AS language,
               coalesce(n.repo_key, '') AS repo_key
        ORDER BY n.path ASC
        LIMIT $limit
        """
        return self._read(
            query,
            {
                "tenant_id": tenant_id,
                "repo_key": repo_key,
                "q": q.lower() if q else None,
                "limit": limit,
            },
        )

    def incoming_edges(
        self, tenant_id: str, target_qns: list[str], repo_key: str | None = None
    ) -> list[dict[str, Any]]:
        if not target_qns:
            return []
        query = """
        MATCH (source)-[r]->(target)
        WHERE source.tenant_id = $tenant_id
          AND target.tenant_id = $tenant_id
          AND type(r) IN $edge_types
          AND target.qualified_name IN $target_qns
          AND ($repo_key IS NULL OR (coalesce(source.repo_key, '') = $repo_key
               AND coalesce(target.repo_key, '') = $repo_key))
        RETURN source.qualified_name AS source_qn, source.name AS source_name,
               labels(source)[0] AS source_label, source.path AS source_path,
               source.line AS source_line, source.end_line AS source_end_line,
               coalesce(source.repo_key, '') AS source_repo_key,
               coalesce(source.resolution, 'heuristic') AS source_resolution,
               type(r) AS edge_type, target.qualified_name AS target_qn
        """
        return self._read(
            query,
            {
                "tenant_id": tenant_id,
                "edge_types": list(IMPACT_EDGE_TYPES),
                "target_qns": list(target_qns),
                "repo_key": repo_key,
            },
        )

    def node_counts(
        self,
        tenant_id: str,
        path_prefix: str | None = None,
        repo_key: str | None = None,
    ) -> dict[str, int]:
        query = """
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
          AND ($path_prefix IS NULL OR n.path STARTS WITH $path_prefix)
          AND ($repo_key IS NULL OR coalesce(n.repo_key, '') = $repo_key)
        RETURN labels(n)[0] AS label, count(n) AS count
        """
        rows = self._read(
            query,
            {
                "tenant_id": tenant_id,
                "path_prefix": path_prefix,
                "repo_key": repo_key,
            },
        )
        return {row["label"]: int(row["count"]) for row in rows if row.get("label")}

    def edge_counts(
        self,
        tenant_id: str,
        path_prefix: str | None = None,
        repo_key: str | None = None,
    ) -> dict[str, int]:
        query = """
        MATCH (a)-[r]->(b)
        WHERE a.tenant_id = $tenant_id
          AND b.tenant_id = $tenant_id
          AND type(r) IN ['IMPORTS', 'CALLS', 'DEFINES', 'INHERITS', 'REFERENCES']
          AND ($path_prefix IS NULL OR a.path STARTS WITH $path_prefix)
          AND ($repo_key IS NULL OR (coalesce(a.repo_key, '') = $repo_key
               AND coalesce(b.repo_key, '') = $repo_key))
        RETURN type(r) AS edge_type, count(r) AS count
        """
        rows = self._read(
            query,
            {
                "tenant_id": tenant_id,
                "path_prefix": path_prefix,
                "repo_key": repo_key,
            },
        )
        return {
            row["edge_type"]: int(row["count"]) for row in rows if row.get("edge_type")
        }

    def top_connected(
        self,
        tenant_id: str,
        path_prefix: str | None = None,
        limit: int = 10,
        repo_key: str | None = None,
    ) -> list[dict[str, Any]]:
        limit = min(max(1, int(limit)), 100)
        query = f"""
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
          AND ($path_prefix IS NULL OR n.path STARTS WITH $path_prefix)
          AND ($repo_key IS NULL OR coalesce(n.repo_key, '') = $repo_key)
        OPTIONAL MATCH (n)-[r]-()
        WHERE r.tenant_id = $tenant_id
        RETURN n.qualified_name AS qualified_name, n.name AS name,
               labels(n)[0] AS label, n.path AS path,
               coalesce(n.repo_key, '') AS repo_key,
               count(r) AS connections
        ORDER BY connections DESC, qualified_name ASC
        LIMIT {limit}
        """
        return self._read(
            query,
            {
                "tenant_id": tenant_id,
                "path_prefix": path_prefix,
                "repo_key": repo_key,
            },
        )

    def index_meta(
        self, tenant_id: str, repo_key: str | None = None
    ) -> dict[str, Any] | None:
        query = """
        MATCH (m:CodeIndexMeta)
        WHERE m.tenant_id = $tenant_id
          AND ($repo_key IS NULL OR m.repo_key = $repo_key)
        RETURN m.repo_key AS repo_key, m.repo_root AS repo_root,
               m.source_commit AS source_commit, m.indexed_at AS indexed_at,
               m.kind AS kind
        ORDER BY m.indexed_at DESC
        LIMIT 1
        """
        rows = self._read(query, {"tenant_id": tenant_id, "repo_key": repo_key})
        return rows[0] if rows else None

    def index_metas(self, tenant_id: str) -> list[dict[str, Any]]:
        query = """
        MATCH (m:CodeIndexMeta)
        WHERE m.tenant_id = $tenant_id
        RETURN m.repo_key AS repo_key, m.repo_root AS repo_root,
               m.source_commit AS source_commit, m.indexed_at AS indexed_at,
               m.kind AS kind
        ORDER BY m.indexed_at DESC
        """
        return self._read(query, {"tenant_id": tenant_id})


def _default_client(client: CodeGraphClient | None) -> CodeGraphClient:
    return client if client is not None else Neo4jCodeGraphClient()


def _git_head_sha(root: str) -> str | None:
    """Current HEAD SHA of the checkout at ``root``, or None.

    A five-line stdlib probe kept local to the retrieval layer (the
    ingestion layer owns the full git machinery). Any failure — no
    git binary, not a checkout, missing directory — yields None so
    callers omit staleness rather than guess it.
    """
    try:
        result = subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def _freshness_block(
    client: CodeGraphClient, tenant_id: str, repo_key: str | None = None
) -> dict[str, Any]:
    """Index-provenance disclosure attached to every query result.

    Always present, additive: ``indexed_commit`` / ``indexed_at``
    mirror the ingestion stamp (None when the graph predates index
    metadata or the client keeps no stamp). ``current_commit`` and
    ``stale`` are added only when the stamped repo root is a checkout
    on this machine whose HEAD can be read — when HEAD cannot be
    checked, ``stale`` is omitted rather than guessed. With
    ``repo_key`` given, the block describes that repo's stamp;
    without one it describes the tenant's most recent stamp, and the
    stamp's ``repo_key`` is included so the reader can tell which
    repo the disclosure is about.
    """
    block: dict[str, Any] = {"indexed_commit": None, "indexed_at": None}
    meta_fn = getattr(client, "index_meta", None)
    if not callable(meta_fn):
        return block
    try:
        meta = meta_fn(tenant_id, repo_key)
    except Exception:
        logger.warning(
            "index_meta lookup failed for tenant %s", tenant_id, exc_info=True
        )
        return block
    if not meta:
        return block
    block["indexed_commit"] = meta.get("source_commit")
    block["indexed_at"] = meta.get("indexed_at")
    block["repo_key"] = meta.get("repo_key")
    root = meta.get("repo_root")
    indexed = meta.get("source_commit")
    if root and indexed:
        head = _git_head_sha(str(root))
        if head is not None:
            block["current_commit"] = head
            block["stale"] = head != indexed
    return block


def _repo_disambiguation(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Disclosure added when unscoped results span several repos.

    Empty dict when the rows touch at most one repo (the common
    single-repo case, whose result shape is unchanged). Otherwise a
    ``repos`` list plus a ``note``: the results are NOT merged —
    every row carries its own ``repo_key`` — but the reader must be
    told more than one repo contributed, and how to scope down.
    """
    keys = sorted({str(row.get("repo_key")) for row in rows if row.get("repo_key")})
    if len(keys) <= 1:
        return {}
    return {
        "repos": keys,
        "note": (
            f"Results span {len(keys)} indexed repos "
            f"({', '.join(keys)}); each row carries its repo_key. "
            "Pass repo to scope the query to one repo."
        ),
    }


def symbol_lookup(
    name: str,
    tenant_id: str = "default",
    client: CodeGraphClient | None = None,
    repo: str | None = None,
) -> dict[str, Any]:
    """Look up a code symbol by qualified name, then by simple name.

    Exact qualified-name matches win: simple-name matches are only
    consulted when no qualified name matches, so a fully-qualified
    query never returns same-named symbols from other modules.
    ``repo`` scopes the lookup to one indexed repo (its repo key);
    without it, matches from every repo are returned — each carrying
    its ``repo_key`` — and a ``repos``/``note`` disclosure is added
    when they span more than one repo.
    """
    graph_client = _default_client(client)
    freshness = _freshness_block(graph_client, tenant_id, repo_key=repo)
    query = (name or "").strip()
    if not query:
        return {
            "query": query,
            "match_type": None,
            "matches": [],
            "freshness": freshness,
        }
    matches = graph_client.find_symbols(tenant_id, qualified_name=query, repo_key=repo)
    if matches:
        return {
            "query": query,
            "match_type": "qualified_name",
            "matches": [_attach_url(match) for match in matches],
            "freshness": freshness,
            **_repo_disambiguation(matches),
        }
    matches = graph_client.find_symbols(tenant_id, name=query, repo_key=repo)
    return {
        "query": query,
        "match_type": "name" if matches else None,
        "matches": [_attach_url(match) for match in matches],
        "freshness": freshness,
        **_repo_disambiguation(matches),
    }


def indexed_file(
    path: str,
    tenant_id: str = "default",
    repo_key: str | None = None,
    client: CodeGraphClient | None = None,
) -> dict[str, Any] | None:
    """Return the indexed CodeFile row for ``path`` under ``tenant_id``.

    This is the tenant-scoping check for serving code file content:
    a repo-relative path is servable only when the tenant's code
    graph holds a CodeFile node for it. Returns ``None`` when the
    tenant has no such file indexed (or the path is blank).
    """
    graph_client = _default_client(client)
    query = (path or "").strip()
    if not query:
        return None
    return graph_client.find_file(tenant_id, query, repo_key=repo_key)


def list_code_files(
    tenant_id: str = "default",
    repo_key: str | None = None,
    q: str | None = None,
    limit: int = 50,
    client: CodeGraphClient | None = None,
) -> list[dict[str, Any]]:
    """List indexed CodeFiles for a tenant (Code Mode file picker).

    ``repo_key`` scopes to one indexed repo; ``q`` substring-filters
    on path/name. Blank ``q``/``repo_key`` mean unfiltered.
    """
    graph_client = _default_client(client)
    return graph_client.list_files(
        tenant_id,
        repo_key=repo_key or None,
        q=(q or "").strip() or None,
        limit=limit,
    )


def _resolution_confidence(
    resolutions: set[str], *, impacted_count: int
) -> dict[str, Any]:
    """ADR-0007 confidence block for an impact verdict.

    ``resolutions`` holds the provenance of every node the verdict
    rests on (roots + impacted callers). A verdict backed only by
    heuristic (AST) resolution is *low* confidence — most importantly
    when it is a "no impact" verdict, because a heuristic miss reads
    exactly like "not reachable", which is the dangerous direction
    for security triage. SCIP-backed verdicts are high; a mix is
    medium.
    """
    if resolutions == {"scip"}:
        block: dict[str, Any] = {"resolution": "scip", "confidence": "high"}
    elif "scip" in resolutions:
        block = {"resolution": "mixed", "confidence": "medium"}
    else:
        block = {"resolution": "heuristic", "confidence": "low"}
    if impacted_count == 0 and block["resolution"] == "heuristic":
        block["confidence_note"] = (
            "No impacted callers were found, but this verdict rests only on "
            "heuristic (AST) edges; a compiler-grade SCIP index could find "
            "callers this graph missed. Treat 'not reachable' as unproven."
        )
    return block


def impact_analysis(
    symbol: str,
    tenant_id: str = "default",
    max_depth: int = 3,
    client: CodeGraphClient | None = None,
    repo: str | None = None,
) -> dict[str, Any]:
    """Reverse-dependency impact: who CALLS/IMPORTS ``symbol``, transitively.

    Resolves ``symbol`` exactly (qualified name first, then simple
    name), then breadth-first walks incoming CALLS/IMPORTS edges from
    the defining node(s). A caller at depth 1 calls/imports the symbol
    directly; deeper entries reach it through a chain of callers.

    The walk is repo-partitioned: a symbol defined in several of the
    tenant's repos is walked once per repo, and callers are only ever
    collected from the repo that defines the root they reach — impact
    never crosses repos. ``repo`` restricts the walk to one repo.
    Without it, impacted entries carry their ``repo_key`` and a
    ``repos``/``note`` disclosure is added when roots span repos.
    """
    graph_client = _default_client(client)
    freshness = _freshness_block(graph_client, tenant_id, repo_key=repo)
    depth_limit = min(max(1, int(max_depth)), MAX_IMPACT_DEPTH)
    lookup = symbol_lookup(symbol, tenant_id=tenant_id, client=graph_client, repo=repo)
    roots = lookup["matches"]
    if not roots:
        return {
            "symbol": symbol,
            "found": False,
            "roots": [],
            "max_depth": depth_limit,
            "impacted": [],
            "freshness": freshness,
            "resolution": "unknown",
            "confidence": "low",
            "confidence_note": (
                "The symbol itself was not found; whether it exists at all "
                "rests on the heuristic index, so absence is unproven."
            ),
        }
    resolutions: set[str] = {
        str(root.get("resolution") or "heuristic") for root in roots
    }
    # Frontier and visited set are keyed by (repo_key, qualified
    # name): the same qualified name in two repos is two distinct
    # nodes, and each repo's walk proceeds independently.
    seen: set[tuple[str, str]] = set()
    frontiers: dict[str, list[str]] = {}
    for root in roots:
        root_key = str(root.get("repo_key") or "")
        root_qn = root["qualified_name"]
        if (root_key, root_qn) not in seen:
            seen.add((root_key, root_qn))
            frontiers.setdefault(root_key, []).append(root_qn)
    impacted: list[dict[str, Any]] = []
    for depth in range(1, depth_limit + 1):
        if not any(frontiers.values()):
            break
        next_frontiers: dict[str, list[str]] = {}
        for root_key, frontier in frontiers.items():
            if not frontier:
                continue
            rows = graph_client.incoming_edges(
                tenant_id, sorted(frontier), repo_key=root_key or None
            )
            for row in rows:
                source_qn = row.get("source_qn")
                if not source_qn:
                    continue
                resolutions.add(str(row.get("source_resolution") or "heuristic"))
                source_key = str(row.get("source_repo_key") or root_key)
                if (source_key, source_qn) in seen:
                    continue
                seen.add((source_key, source_qn))
                next_frontiers.setdefault(source_key, []).append(source_qn)
                entry = {
                    "qualified_name": source_qn,
                    "name": row.get("source_name"),
                    "label": row.get("source_label"),
                    "path": row.get("source_path"),
                    "line": row.get("source_line"),
                    "end_line": row.get("source_end_line"),
                    "depth": depth,
                    "via_edge": row.get("edge_type"),
                    "via_target": row.get("target_qn"),
                }
                if source_key:
                    entry["repo_key"] = source_key
                url = code_source_url(entry["path"], entry["line"], entry["end_line"])
                if url is not None:
                    entry["url"] = url
                impacted.append(entry)
        frontiers = next_frontiers
    impacted.sort(key=lambda item: (item["depth"], item["qualified_name"]))
    return {
        "symbol": symbol,
        "found": True,
        "roots": roots,
        "max_depth": depth_limit,
        "impacted": impacted,
        "freshness": freshness,
        **_resolution_confidence(resolutions, impacted_count=len(impacted)),
        **_repo_disambiguation(roots),
    }


def _tenant_repo_keys(
    client: CodeGraphClient, tenant_id: str, rows: list[dict[str, Any]]
) -> list[str]:
    """Sorted repo keys a tenant-wide result spans.

    From the tenant's index stamps when the client keeps them (the
    authoritative list of indexed repos); otherwise from the repo
    keys carried by the result rows themselves.
    """
    metas_fn = getattr(client, "index_metas", None)
    if callable(metas_fn):
        try:
            keys = {
                str(meta.get("repo_key"))
                for meta in metas_fn(tenant_id) or []
                if meta.get("repo_key")
            }
        except Exception:
            logger.warning(
                "index_metas lookup failed for tenant %s", tenant_id, exc_info=True
            )
            keys = set()
        if keys:
            return sorted(keys)
    return sorted({str(row.get("repo_key")) for row in rows if row.get("repo_key")})


def repo_overview(
    tenant_id: str = "default",
    path_prefix: str | None = None,
    client: CodeGraphClient | None = None,
    top_limit: int = 10,
    repo: str | None = None,
) -> dict[str, Any]:
    """Counts per node/edge type plus the most-connected symbols.

    ``repo`` scopes every count to one indexed repo. Without it the
    counts span the tenant's whole graph; when that graph holds more
    than one repo, a ``repos`` list discloses which repos the totals
    cover (the counts are the tenant's, not one repo's).
    """
    graph_client = _default_client(client)
    node_counts = graph_client.node_counts(tenant_id, path_prefix, repo_key=repo)
    edge_counts = graph_client.edge_counts(tenant_id, path_prefix, repo_key=repo)
    top_rows = [
        _attach_url(row)
        for row in graph_client.top_connected(
            tenant_id, path_prefix, limit=top_limit, repo_key=repo
        )
    ]
    result: dict[str, Any] = {
        "tenant_id": tenant_id,
        "path_prefix": path_prefix,
        "node_counts": node_counts,
        "edge_counts": edge_counts,
        "total_nodes": sum(node_counts.values()),
        "total_edges": sum(edge_counts.values()),
        "freshness": _freshness_block(graph_client, tenant_id, repo_key=repo),
        # top_connected rows carry a path but no line, so their URLs
        # are plain file:// links without a line anchor.
        "top_connected": top_rows,
    }
    if repo is None:
        repo_keys = _tenant_repo_keys(graph_client, tenant_id, top_rows)
        if len(repo_keys) > 1:
            result["repos"] = repo_keys
    return result


def list_indexed_repos(
    tenant_id: str = "default",
    client: CodeGraphClient | None = None,
) -> list[dict[str, Any]]:
    """List every indexed repository for ``tenant_id`` with file/symbol counts and freshness."""
    graph_client = _default_client(client)
    metas_fn = getattr(graph_client, "index_metas", None)
    metas = metas_fn(tenant_id) if callable(metas_fn) else []
    meta_by_key = {
        str(meta["repo_key"]): meta for meta in (metas or []) if meta.get("repo_key")
    }
    if not meta_by_key:
        top_rows = graph_client.top_connected(tenant_id, None, limit=50)
        for rk in _tenant_repo_keys(graph_client, tenant_id, top_rows):
            meta_by_key.setdefault(rk, {"repo_key": rk})

    repos: list[dict[str, Any]] = []
    for rk, meta in meta_by_key.items():
        node_counts = graph_client.node_counts(tenant_id, None, repo_key=rk)
        file_count = int(node_counts.get("CodeFile", 0) or node_counts.get("File", 0))
        symbol_count = sum(
            int(v)
            for k, v in node_counts.items()
            if k not in ("CodeFile", "File", "CodeIndexMeta")
        )
        freshness = _freshness_block(graph_client, tenant_id, repo_key=rk)
        repos.append(
            {
                "repo_key": rk,
                "display_name": rk,
                "root_path": meta.get("repo_root"),
                "file_count": file_count,
                "symbol_count": symbol_count,
                "indexed_commit": freshness.get("indexed_commit"),
                "current_commit": freshness.get("current_commit"),
                "indexed_at": freshness.get("indexed_at"),
                "is_stale": bool(freshness.get("stale", False)),
            }
        )
    return repos


__all__ = [
    "CODE_NODE_LABELS",
    "IMPACT_EDGE_TYPES",
    "MAX_IMPACT_DEPTH",
    "CodeGraphClient",
    "Neo4jCodeGraphClient",
    "code_source_url",
    "impact_analysis",
    "list_indexed_repos",
    "repo_overview",
    "symbol_lookup",
]
