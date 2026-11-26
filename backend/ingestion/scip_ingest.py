"""Optional SCIP ingestion: compiler-grade cross-file code resolution.

SCIP (Sourcegraph Code Intelligence Protocol) indexers emit precise,
compiler-resolved symbol information. This module ingests the JSON
rendering of an index — the output of ``scip print --json index.scip``
— using only the stdlib :mod:`json` module, so it adds **zero** new
dependencies (decoding the binary protobuf form would require the
``protobuf`` package; that is deliberately not done here).

Input shape (per document in ``documents[]``):

* ``relative_path`` — path of the indexed file, relative to the repo.
* ``language`` — SCIP language id for the file (may be empty).
* ``occurrences[]`` — each with ``range`` (SCIP range, see below),
  ``symbol`` (SCIP symbol string), ``symbol_roles`` (bitmask int;
  bit ``1`` = Definition) and optional ``enclosing_range``.
* ``symbols[]`` — each with ``symbol``, ``kind``, ``display_name``,
  ``signature_documentation`` / ``documentation`` and
  ``relationships[]`` (relationships are not turned into edges here).

A SCIP range is ``[line, start_char, end_char]`` for a single line or
``[start_line, start_char, end_line, end_char]`` for a multi-line span;
lines and characters are zero-based.

Qualified-name scheme
---------------------
Code nodes are keyed in Neo4j by ``structural_key(tenant_id, label,
<repo_key>::<qualified_name>)`` (see :mod:`backend.ingestion.code_graph`),
so the qualified name must be stable across runs and must not merge distinct
symbols that happen to share a display name in different files. A
SCIP index has no checkout to derive a repo key from, so
:func:`write_scip_graph` namespaces the whole index under the
payload's ``metadata.project_root`` (or ``"scip-upload"``).

* ``CodeFile`` nodes use ``qualified_name = relative_path`` — exactly
  like :func:`backend.ingestion.code_graph.parse_repo`.
* A defined symbol's qualified name is
  ``"<relative_path>::<descriptor_path>"`` where ``descriptor_path``
  is derived conservatively from the SCIP symbol string: the scheme /
  package prefix (everything up to the descriptor section) is dropped,
  a leading backtick-quoted descriptor (indexers such as scip-python
  put the file path there, which the ``relative_path`` prefix already
  carries) is dropped, backticks elsewhere are removed, and the
  remaining descriptor path is kept verbatim (e.g.
  ``scip-python ... `pkg/mod.py`Greeter#greet().`` becomes
  ``pkg/mod.py::Greeter#greet().`` — the descriptor suffixes
  ``#`` / ``().`` / ``.`` are retained because they distinguish types,
  methods and terms in SCIP). Prefixing with the defining file's
  ``relative_path`` (via the ``::`` separator, which cannot appear in
  the descriptor of a single file's local namespace in practice) means
  two files defining a same-named symbol never collide, while repeated
  ingestion of the same index reproduces the exact same names.
* ``local <n>`` symbols are file-local by definition; their descriptor
  path is ``local/<n>``, so the same prefixing keeps them per-file.

Edges
-----
* ``DEFINES`` — ``CodeFile`` -> each symbol defined in that file.
* ``REFERENCES`` — for every occurrence whose ``symbol_roles`` does
  **not** include the Definition bit and whose symbol is defined in
  some document of the same index: an edge from the enclosing defined
  symbol of that occurrence to the target symbol node. The enclosing
  symbol is found by span containment: definition occurrences carry an
  ``enclosing_range`` (the full extent of the definition), and the
  innermost definition span containing the reference wins. A reference
  occurrence that itself carries an ``enclosing_range`` is matched
  against that span first. When no defined symbol encloses the
  reference, the edge originates at the file's ``CodeFile`` node.

Symbols that are referenced but **not** defined anywhere in the index
produce no edge and no node. ``write_code_graph`` creates placeholder
nodes for edge targets, so emitting edges to undefined symbols would
flood the graph with external placeholders; SCIP indexes already
distinguish definitions, so under-claiming here is exact, not lossy,
for everything the index itself defines.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from backend.ingestion.code_graph import (
    MAX_INGEST_EDGES,
    MAX_INGEST_NODES,
    CodeEdge,
    CodeGraph,
    CodeNode,
    write_code_graph,
    write_index_meta,
)

logger = logging.getLogger(__name__)

# SCIP SymbolRole bitmask: bit 0 (value 1) marks a definition.
_DEFINITION_ROLE = 1

_CLASS_KINDS = {
    "class",
    "interface",
    "struct",
    "enum",
    "trait",
    "annotation",
    "namespace",
    "object",
    "type",
    "typeparameter",
    "union",
}
_FUNCTION_KINDS = {
    "method",
    "function",
    "constructor",
    "field",
    "property",
    "variable",
    "parameter",
    "constant",
    "event",
    "getter",
    "setter",
    "macro",
}

# Trailing descriptor decorations stripped when deriving a display name.
_NAME_SPLIT_RE = re.compile(r"[/#.\s]+")


def _normalize_range(raw: Any) -> tuple[int, int, int, int] | None:
    """Normalize a SCIP range to (start_line, start_char, end_line, end_char)."""
    if not isinstance(raw, (list, tuple)):
        return None
    try:
        values = [int(v) for v in raw]
    except (TypeError, ValueError):
        return None
    if len(values) == 3:
        line, start, end = values
        return (line, start, line, end)
    if len(values) == 4:
        return (values[0], values[1], values[2], values[3])
    return None


def _range_contains(outer: tuple[int, int, int, int], inner: tuple[int, int, int, int]) -> bool:
    return (outer[0], outer[1]) <= (inner[0], inner[1]) and (inner[2], inner[3]) <= (
        outer[2],
        outer[3],
    )


def _range_size(span: tuple[int, int, int, int]) -> tuple[int, int]:
    return (span[2] - span[0], span[3] - span[1])


def descriptor_path(symbol: str) -> str:
    """Return the human-readable descriptor path of a SCIP symbol string.

    Drops the ``<scheme> <manager> <package> <version>`` prefix when
    present, removes backticks, and keeps the descriptor section
    verbatim. ``local <n>`` symbols map to ``local/<n>``. A symbol that
    does not match either shape is returned backtick-stripped, so the
    result is still stable (if less pretty).
    """
    text = str(symbol or "").strip()
    if not text:
        return ""
    if text.startswith("local "):
        return "local/" + text[len("local ") :].strip().replace(" ", "/")
    parts = text.split(" ")
    # Global symbols: scheme, manager, package name, package version,
    # then one or more descriptor tokens.
    descriptors = " ".join(parts[4:]) if len(parts) > 4 else text
    if descriptors.startswith("`"):
        # Drop a leading backtick-quoted descriptor (usually the file
        # path, already carried by the qualified-name prefix).
        closing = descriptors.find("`", 1)
        if closing > 0:
            descriptors = descriptors[closing + 1 :].lstrip("/")
    return descriptors.replace("`", "").strip()


def symbol_display_name(symbol: str, fallback: str = "") -> str:
    """Best-effort human name for a SCIP symbol (display_name wins)."""
    if fallback:
        return str(fallback)
    path = descriptor_path(symbol)
    tokens = [t for t in _NAME_SPLIT_RE.split(path) if t and t not in ("()", "[]")]
    return tokens[-1] if tokens else path or str(symbol)


def _label_for_kind(kind: Any) -> str:
    """Map a SCIP symbol kind (string name or enum int) to a node label."""
    if isinstance(kind, str):
        normalized = kind.replace("_", "").replace(" ", "").lower()
        # Enum names arrive in forms like "Class", "CLASS" or, from some
        # indexers, qualified strings; substring checks are conservative
        # because the class-like names do not overlap the function ones.
        if any(name in normalized for name in _CLASS_KINDS):
            return "Class"
        if any(name in normalized for name in _FUNCTION_KINDS):
            return "Function"
    return "Function"


def _is_definition(occurrence: dict[str, Any]) -> bool:
    try:
        roles = int(occurrence.get("symbol_roles") or 0)
    except (TypeError, ValueError):
        return False
    return bool(roles & _DEFINITION_ROLE)


class _ScipBuilder:
    """Accumulates SCIP nodes/edges, deduplicating both by identity."""

    def __init__(self, repo_key: str = "") -> None:
        self.nodes: dict[tuple[str, str, str], CodeNode] = {}
        self.edges: dict[tuple[str, str, str], CodeEdge] = {}
        # The repo the whole index belongs to, stamped onto every
        # node (and, via source nodes, every edge) exactly as
        # code_graph's parse builder stamps its parses.
        self.repo_key = repo_key
        # symbol string -> defined node, across every document
        self.defined: dict[str, CodeNode] = {}
        # per-document definition spans: relative_path -> [(span, node)]
        self.def_spans: dict[str, list[tuple[tuple[int, int, int, int], CodeNode]]] = {}

    def add_node(self, node: CodeNode) -> CodeNode:
        if self.repo_key and not node.repo_key:
            node.repo_key = self.repo_key
        existing = self.nodes.get(node.key)
        if existing is not None:
            return existing
        self.nodes[node.key] = node
        return node

    def add_edge(self, edge_type: str, source: CodeNode, target: CodeNode) -> None:
        if source.key == target.key:
            return
        key = (edge_type, source.qualified_name, target.qualified_name)
        if key not in self.edges:
            self.edges[key] = CodeEdge(
                type=edge_type,
                source_qn=source.qualified_name,
                source_label=source.label,
                target_qn=target.qualified_name,
                target_label=target.label,
                repo_key=source.repo_key,
            )

    def build(self) -> CodeGraph:
        graph = CodeGraph(nodes=list(self.nodes.values()), edges=list(self.edges.values()))
        if len(graph.nodes) > MAX_INGEST_NODES or len(graph.edges) > MAX_INGEST_EDGES:
            raise ValueError(
                f"SCIP graph too large: {len(graph.nodes)} nodes / "
                f"{len(graph.edges)} edges (limits {MAX_INGEST_NODES}/"
                f"{MAX_INGEST_EDGES})"
            )
        return graph


def _definition_lines(document: dict[str, Any]) -> dict[str, int]:
    """First definition-occurrence line (1-based) per symbol in a document."""
    lines: dict[str, int] = {}
    for occurrence in document.get("occurrences") or []:
        if not isinstance(occurrence, dict) or not _is_definition(occurrence):
            continue
        symbol = str(occurrence.get("symbol") or "")
        span = _normalize_range(occurrence.get("range"))
        if symbol and span is not None and symbol not in lines:
            lines[symbol] = span[0] + 1
    return lines


def _add_file_and_symbols(
    builder: _ScipBuilder, document: dict[str, Any]
) -> CodeNode | None:
    """Create the CodeFile node and one node per defined symbol."""
    relative_path = str(document.get("relative_path") or "")
    if not relative_path:
        return None
    language = str(document.get("language") or "")
    file_node = builder.add_node(
        CodeNode(
            label="CodeFile",
            name=relative_path.rsplit("/", 1)[-1],
            qualified_name=relative_path,
            path=relative_path,
            line=1,
            language=language,
            resolved=True,
        )
    )
    def_lines = _definition_lines(document)
    for info in document.get("symbols") or []:
        if not isinstance(info, dict):
            continue
        symbol = str(info.get("symbol") or "")
        if not symbol:
            continue
        _add_symbol_node(builder, file_node, relative_path, language, symbol, info, def_lines)
    # Symbols defined by a definition occurrence but absent from
    # symbols[] still get a node (default Function label).
    for symbol in def_lines:
        if symbol not in builder.defined:
            _add_symbol_node(
                builder,
                file_node,
                relative_path,
                language,
                symbol,
                {"symbol": symbol},
                def_lines,
            )
    return file_node


def _add_symbol_node(
    builder: _ScipBuilder,
    file_node: CodeNode,
    relative_path: str,
    language: str,
    symbol: str,
    info: dict[str, Any],
    def_lines: dict[str, int],
) -> CodeNode:
    label = _label_for_kind(info.get("kind"))
    qualified_name = f"{relative_path}::{descriptor_path(symbol)}"
    node = builder.add_node(
        CodeNode(
            label=label,
            name=symbol_display_name(symbol, str(info.get("display_name") or "")),
            qualified_name=qualified_name,
            path=relative_path,
            line=int(def_lines.get(symbol) or 0),
            language=language,
            resolved=True,
        )
    )
    builder.defined[symbol] = node
    builder.add_edge("DEFINES", file_node, node)
    return node


def _record_def_spans(builder: _ScipBuilder, document: dict[str, Any], relative_path: str) -> None:
    spans: list[tuple[tuple[int, int, int, int], CodeNode]] = []
    for occurrence in document.get("occurrences") or []:
        if not isinstance(occurrence, dict) or not _is_definition(occurrence):
            continue
        node = builder.defined.get(str(occurrence.get("symbol") or ""))
        if node is None or node.path != relative_path:
            continue
        span = _normalize_range(
            occurrence.get("enclosing_range") or occurrence.get("range")
        )
        if span is not None:
            spans.append((span, node))
    builder.def_spans[relative_path] = spans


def _enclosing_node(
    builder: _ScipBuilder,
    relative_path: str,
    occurrence: dict[str, Any],
    file_node: CodeNode,
) -> CodeNode:
    """Innermost defined symbol enclosing a reference occurrence."""
    spans = builder.def_spans.get(relative_path) or []
    if not spans:
        return file_node
    probe = _normalize_range(
        occurrence.get("enclosing_range") or occurrence.get("range")
    )
    if probe is None:
        return file_node
    candidates = [
        (span, node) for span, node in spans if _range_contains(span, probe)
    ]
    if not candidates:
        # A reference's own enclosing_range may be the *reference's*
        # extent inside the definition rather than contained by the
        # stored definition span in some indexer outputs; also accept
        # a definition span contained in the probe.
        candidates = [
            (span, node) for span, node in spans if _range_contains(probe, span)
        ]
    if not candidates:
        return file_node
    candidates.sort(key=lambda item: _range_size(item[0]))
    return candidates[0][1]


def _add_reference_edges(
    builder: _ScipBuilder, document: dict[str, Any], file_node: CodeNode
) -> None:
    relative_path = file_node.qualified_name
    for occurrence in document.get("occurrences") or []:
        if not isinstance(occurrence, dict) or _is_definition(occurrence):
            continue
        target = builder.defined.get(str(occurrence.get("symbol") or ""))
        if target is None:
            continue  # referenced but not defined in this index: no edge
        source = _enclosing_node(builder, relative_path, occurrence, file_node)
        builder.add_edge("REFERENCES", source, target)


def parse_scip_payload(payload: dict[str, Any], repo_key: str = "") -> CodeGraph:
    """Parse a ``scip print --json`` payload dict into a :class:`CodeGraph`.

    Pure: no database or network access. Raises :class:`ValueError`
    for a malformed payload or when the resulting graph would exceed
    ``MAX_INGEST_NODES`` / ``MAX_INGEST_EDGES``. ``repo_key``
    namespaces every node/edge (see the module docstring); pure
    callers that only inspect the graph may leave it empty.
    """
    if not isinstance(payload, dict):
        raise ValueError("SCIP payload must be a JSON object")  # noqa: TRY004
    documents = payload.get("documents")
    if not isinstance(documents, list):
        raise ValueError("SCIP payload must contain a 'documents' list")  # noqa: TRY004
    builder = _ScipBuilder(repo_key=repo_key)
    file_nodes: dict[str, CodeNode] = {}
    for document in documents:
        if not isinstance(document, dict):
            continue
        file_node = _add_file_and_symbols(builder, document)
        if file_node is not None:
            file_nodes[file_node.qualified_name] = file_node
            _record_def_spans(builder, document, file_node.qualified_name)
    # Second pass: references may target symbols defined in documents
    # parsed later, so edges are added only once every definition in
    # the index is known.
    for document in documents:
        if not isinstance(document, dict):
            continue
        file_node = file_nodes.get(str(document.get("relative_path") or ""))
        if file_node is not None:
            _add_reference_edges(builder, document, file_node)
    graph = builder.build()
    logger.info(
        "Parsed SCIP index: %d documents, %d nodes, %d edges",
        len(file_nodes),
        len(graph.nodes),
        len(graph.edges),
    )
    return graph


def parse_scip_text(text: str) -> CodeGraph:
    """Parse the raw text output of ``scip print --json``."""
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid SCIP JSON: {exc}") from exc
    return parse_scip_payload(payload)


def load_scip_payload(text: str) -> dict[str, Any]:
    """Parse raw ``scip print --json`` text into the payload dict."""
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid SCIP JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("SCIP payload must be a JSON object")  # noqa: TRY004
    return payload


def write_scip_graph(
    client: Any, payload: dict[str, Any], tenant_id: str = "default"
) -> dict[str, int]:
    """Parse a SCIP payload and persist it via ``write_code_graph``.

    Reuses :func:`backend.ingestion.code_graph.write_code_graph`, so
    persistence follows the same tenant-scoped, parameterized,
    whitelist-validated path as every other code-graph write. Returns
    the writer's ``{"nodes_written", "edges_written"}`` counts.

    Also stamps the index metadata (see
    :func:`backend.ingestion.code_graph.write_index_meta`): a SCIP
    payload carries no commit SHA, so provenance records the
    timestamp and the payload's ``metadata.project_root`` when
    present — the commit stays unknown rather than fabricated. The
    same value namespaces the graph's nodes as their repo key, so
    the stamp and the nodes it describes always agree.
    """
    metadata = payload.get("metadata") or {}
    repo_key = str(metadata.get("project_root") or "scip-upload")
    graph = parse_scip_payload(payload, repo_key=repo_key)
    counts = write_code_graph(client, graph, tenant_id=tenant_id)
    write_index_meta(
        client,
        tenant_id,
        repo_key=repo_key,
        repo_root="",
        source_commit=None,
        kind="scip",
    )
    return counts


__all__ = [
    "descriptor_path",
    "load_scip_payload",
    "parse_scip_payload",
    "parse_scip_text",
    "symbol_display_name",
    "write_scip_graph",
]
