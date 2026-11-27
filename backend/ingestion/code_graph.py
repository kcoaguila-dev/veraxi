"""Repo X-Ray: parse a repository tree into a structural code graph.

Two separable halves:

* :func:`parse_repo` — pure parsing. Walks a repo tree and returns an
  in-memory :class:`CodeGraph` (nodes + edges) with no database, network
  or LLM involved, so tests can assert on the model directly.
* :func:`write_code_graph` — persistence. Writes a parsed graph to Neo4j
  through the existing storage client, following ``graph_write.py``
  patterns: tenant-scoped, parameterized Cypher only (labels and
  relationship types come from fixed whitelists in this module, never
  from user input).

Node/edge model:

* Nodes: ``CodeFile``, ``CodeModule``, ``Class``, ``Function`` with
  properties ``name``, ``qualified_name``, ``path``, ``line``,
  ``tenant_id`` and ``language``. Class/Function nodes parsed from a
  real AST also carry ``end_line`` (the last line of the definition);
  parsers that only know the declaration line leave it unset.
* Edges: ``IMPORTS`` (module -> imported module), ``CALLS``
  (function/module -> resolved callee), ``DEFINES`` (file -> its module,
  module -> top-level class/function, class -> its methods) and
  ``INHERITS`` (class -> resolved base class).

Qdrant note (per ``docs/evidence-first-plan.md``): code nodes are
structural AST-derived nodes, NOT text chunks, so they carry NO Qdrant
point ID and the chunk dual-write rule does not apply to them. Where a
code file also has ingested chunks, the two are linked only by the
shared ``path`` property — no point IDs are invented here.

Index freshness: every ingestion entry point stamps a
``CodeIndexMeta`` node (see :func:`write_index_meta`) with the source
commit SHA (when the repo is a git checkout) and an ``indexed_at``
timestamp, so consumers can disclose staleness instead of silently
serving a graph that no longer matches the code. :func:`update_repo_code_graph`
refreshes a stored graph incrementally from ``git diff`` — only
changed files (plus the owners of edges into them, whose stored
edges must be re-resolved) are re-parsed.

Repo namespacing: every code node carries a ``repo_key`` identifying
the repo it was parsed from (see :func:`derive_repo_key`), and the
key is part of the node's structural identity, so one tenant can
index several repos without same-pathed, same-named symbols merging
into one node. Queries and the incremental updater scope by it.
Graphs ingested before namespacing have no ``repo_key`` on their
nodes; they pick it up on their next (re)index — there is no data
migration.

Parsing is deliberately conservative (under-claim):

* Python files use the stdlib ``ast`` module. Call targets are recorded
  only when they resolve conservatively: a bare name matching a
  module-level function defined in the same file or a symbol brought in
  by a from-import; ``self.``/``cls.`` attribute calls matching a method
  of the enclosing class; or ``alias.func()`` where ``alias`` is an
  imported module. Module-level assignment aliases (``public =
  _private``) and transitive ``__init__`` re-exports resolve to the
  defining symbol (ADR-0007). Dynamic calls, calls on arbitrary objects and
  unresolved names produce no ``CALLS`` edge.
* Dart/JS/TS files use conservative regexes for import / require /
  export-from statements and class / function declarations only. No
  ``CALLS`` or method-level edges are claimed for these languages.
* Inheritance bases are recorded only when they resolve to a class
  defined in the same file or to an imported symbol; unresolved bases
  are skipped (the writer still creates placeholder nodes for resolved
  targets that live outside the parsed tree, e.g. an imported module).

File filtering mirrors ``backend/services/github_sync.py`` conventions
(skipped directories/files, binary extensions, ``MAX_FILE_BYTES``),
duplicated here as constants because ingestion must not import the
services layer.
"""

from __future__ import annotations

import ast
import json
import logging
import os
import posixpath
import re
import subprocess
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

MAX_FILE_BYTES = 200_000

_SKIPPED_DIRS = {
    "node_modules",
    "vendor",
    ".git",
    "dist",
    "build",
    "__pycache__",
    ".venv",
    "venv",
    "env",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".dart_tool",
}
_SKIPPED_FILES = {
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "poetry.lock",
    "Cargo.lock",
    "composer.lock",
    "Gemfile.lock",
    "go.sum",
}
_BINARY_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip",
    ".gz", ".tar", ".woff", ".woff2", ".ttf", ".eot", ".mp3", ".mp4",
    ".mov", ".bin", ".exe", ".dll", ".so", ".dylib", ".class", ".pyc",
    ".wasm", ".parquet", ".npy", ".pt", ".onnx",
}

_LANGUAGE_BY_EXTENSION = {
    ".py": "python",
    ".dart": "dart",
    ".js": "javascript",
    ".jsx": "javascript",
    ".mjs": "javascript",
    ".cjs": "javascript",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".go": "go",
    ".rs": "rust",
    ".java": "java",
    ".c": "c",
    ".h": "c",
    ".cpp": "cpp",
    ".cc": "cpp",
    ".cxx": "cpp",
    ".hpp": "cpp",
    ".cs": "csharp",
    ".rb": "ruby",
    ".php": "php",
    ".kt": "kotlin",
    ".kts": "kotlin",
    ".swift": "swift",
    ".scala": "scala",
    ".sh": "bash",
    ".bash": "bash",
}

NODE_LABELS = ("CodeFile", "CodeModule", "Class", "Function")
EDGE_TYPES = ("IMPORTS", "CALLS", "DEFINES", "INHERITS", "REFERENCES")


@dataclass
class CodeNode:
    """One structural code node (file, module, class or function)."""

    label: str
    name: str
    qualified_name: str
    path: str
    line: int
    language: str
    # False only for placeholder nodes standing in for a target that
    # lives outside the parsed tree (external / unresolved). Parsed
    # nodes are always resolved.
    resolved: bool = True
    # Last line of the definition (1-based, inclusive) when the parser
    # knows the symbol's extent (Python ``ast`` / tree-sitter). None
    # when only the declaration line is known — never guessed.
    end_line: int | None = None
    # Identity of the repo this node was parsed from (see
    # :func:`derive_repo_key`). Part of the node's identity: two
    # repos in one tenant may define the same qualified name in the
    # same relative path, and their nodes must never merge. Empty
    # only for graphs built by hand, outside every ingestion path.
    repo_key: str = ""
    # Resolution provenance (ADR-0007): how this node's identity was
    # resolved — "scip" for compiler-grade SCIP index data,
    # "heuristic" for AST / tree-sitter inference. This field is the
    # one place the provenance vocabulary is defined; consumers
    # (e.g. impact_analysis confidence) read it from the stored node
    # properties. Edges inherit the provenance of the partition that
    # wrote them: a SCIP write replaces the nodes (and therefore the
    # edges) of the files it covers — see
    # :func:`backend.ingestion.scip_ingest.write_scip_graph`.
    resolution: str = "heuristic"

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.repo_key, self.label, self.qualified_name)

    def properties(self, tenant_id: str) -> dict[str, Any]:
        props: dict[str, Any] = {
            "name": self.name,
            "qualified_name": self.qualified_name,
            "path": self.path,
            "line": self.line,
            "tenant_id": tenant_id,
            "language": self.language,
            "resolved": self.resolved,
            "repo_key": self.repo_key,
            "resolution": self.resolution,
        }
        if self.end_line is not None:
            props["end_line"] = self.end_line
        return props


@dataclass
class CodeEdge:
    """One directed edge between two nodes, by qualified name.

    ``target_label`` names the label of the target node so the writer
    can create a placeholder node for a resolved target that was not
    itself parsed (e.g. an imported external module). ``repo_key``
    is the repo of the source node; an edge never crosses repos,
    because both endpoints are resolved within one repo's parse.
    """

    type: str
    source_qn: str
    source_label: str
    target_qn: str
    target_label: str
    repo_key: str = ""


@dataclass
class CodeGraph:
    """In-memory code graph: the pure output of :func:`parse_repo`."""

    nodes: list[CodeNode] = field(default_factory=list)
    edges: list[CodeEdge] = field(default_factory=list)

    def node(self, label: str, qualified_name: str) -> CodeNode | None:
        for node in self.nodes:
            if node.label == label and node.qualified_name == qualified_name:
                return node
        return None

    def edges_of(self, edge_type: str) -> list[CodeEdge]:
        return [edge for edge in self.edges if edge.type == edge_type]


class _GraphBuilder:
    """Accumulates nodes/edges, deduplicating both by identity."""

    def __init__(
        self,
        known_target_labels: dict[str, str] | None = None,
        repo_key: str = "",
    ) -> None:
        self.nodes: dict[tuple[str, str, str], CodeNode] = {}
        self.edges: dict[tuple[str, str, str], CodeEdge] = {}
        # Labels of nodes that already exist outside this parse (the
        # surviving part of a stored graph during an incremental
        # update). Consulted at build() time so an edge into an
        # un-reparsed file still gets its target label corrected,
        # exactly as a full parse of the whole tree would correct it.
        self.known_target_labels = dict(known_target_labels or {})
        # Cross-file symbol aliases (ADR-0007): qualified name a symbol
        # is *bound* under in some module (a from-imported or
        # assignment-aliased name, e.g. a package ``__init__``
        # re-export) -> qualified name it ultimately refers to.
        # Consulted at build() time so edges recorded against a
        # re-export name are rewritten to the defining symbol.
        self.symbol_aliases: dict[str, str] = {}
        # Per-file Dart AST metadata for cross-file import/inherit/call
        # resolution (ADR-0008). Empty when no Dart files are parsed.
        self.dart_contexts: dict[str, _DartFileContext] = {}
        self.dart_package_roots: dict[str, str] = {}
        # Per-file TS/JS and Go AST metadata for cross-file resolution.
        self.ts_contexts: dict[str, _TsJsFileContext] = {}
        self.tsconfig_paths: tuple[str, dict[str, list[str]]] = ("", {})
        self.go_contexts: dict[str, _GoFileContext] = {}
        self.go_module_prefix: str | None = None
        # The repo every node/edge in this parse belongs to. Parsers
        # create nodes without a repo identity; the builder stamps
        # this one onto each of them (and onto edges, via their
        # source node) so identity is uniform across the graph.
        self.repo_key = repo_key

    def add_node(self, node: CodeNode) -> CodeNode:
        if self.repo_key and not node.repo_key:
            node.repo_key = self.repo_key
        existing = self.nodes.get(node.key)
        if existing is not None:
            return existing
        self.nodes[node.key] = node
        return node

    def add_edge(
        self, edge_type: str, source: CodeNode, target_qn: str, target_label: str
    ) -> None:
        if source.qualified_name == target_qn and source.label == target_label:
            return
        key = (edge_type, source.qualified_name, target_qn)
        if key not in self.edges:
            self.edges[key] = CodeEdge(
                type=edge_type,
                source_qn=source.qualified_name,
                source_label=source.label,
                target_qn=target_qn,
                target_label=target_label,
                repo_key=source.repo_key,
            )

    def register_symbol_alias(self, alias_qn: str, target_qn: str) -> None:
        """Record that ``alias_qn`` is a binding for ``target_qn``.

        Used for re-exports and assignment aliases (ADR-0007): the
        alias name itself has no defining node, so edges aimed at it
        would otherwise land on a placeholder and impact analysis
        would report zero callers for the real symbol.
        """
        if alias_qn and target_qn and alias_qn != target_qn:
            self.symbol_aliases.setdefault(alias_qn, target_qn)

    def _resolve_alias_target(self, target_qn: str, parsed_qns: set[str]) -> str:
        """Follow the alias chain for ``target_qn`` to a parsed symbol.

        Returns ``target_qn`` unchanged when it is itself a parsed
        symbol (a real definition always wins over an alias binding),
        when no chain exists, or when the chain does not end at a
        parsed symbol (external targets keep their placeholder name).
        """
        if target_qn in parsed_qns or target_qn not in self.symbol_aliases:
            return target_qn
        seen = {target_qn}
        current = target_qn
        while current in self.symbol_aliases:
            nxt = self.symbol_aliases[current]
            if nxt in seen:
                return target_qn
            seen.add(nxt)
            current = nxt
            if current in parsed_qns:
                return current
        return target_qn

    def build(self) -> CodeGraph:
        if self.dart_contexts:
            _resolve_dart_builder(self)
        if self.ts_contexts:
            _resolve_ts_builder(self)
        if self.go_contexts:
            _resolve_go_builder(self)
        # A qualified name identifies one symbol regardless of label;
        # when the target was parsed, correct the edge's target label
        # to the parsed node's label (e.g. a call to an imported class).
        # Nodes parsed in this pass win over the externally-known
        # labels (which describe files this pass did not re-parse).
        label_by_qn = {
            **self.known_target_labels,
            **{node.qualified_name: node.label for node in self.nodes.values()},
        }
        parsed_qns = set(label_by_qn)
        edges = []
        seen_edges: set[tuple[str, str, str, str, str]] = set()
        for edge in self.edges.values():
            target_qn = edge.target_qn
            if edge.type in ("CALLS", "INHERITS", "REFERENCES"):
                target_qn = self._resolve_alias_target(target_qn, parsed_qns)
            parsed_label = label_by_qn.get(target_qn)
            target_label = edge.target_label
            if parsed_label is not None:
                target_label = parsed_label
            if target_qn != edge.target_qn or target_label != edge.target_label:
                edge = CodeEdge(
                    type=edge.type,
                    source_qn=edge.source_qn,
                    source_label=edge.source_label,
                    target_qn=target_qn,
                    target_label=target_label,
                    repo_key=edge.repo_key,
                )
            # Alias rewriting can make two recorded edges identical
            # (a caller using both the alias and the real name).
            edge_key = (
                edge.type,
                edge.source_label,
                edge.source_qn,
                edge.target_label,
                edge.target_qn,
            )
            if edge_key not in seen_edges:
                seen_edges.add(edge_key)
                edges.append(edge)
        return CodeGraph(nodes=list(self.nodes.values()), edges=edges)


def _is_parseable_file(path: Path, root: Path) -> bool:
    """True when ``path`` is a supported source file per sync conventions."""
    if path.is_symlink() or not path.is_file():
        return False
    try:
        if os.path.commonpath([str(root), os.path.realpath(path)]) != str(root):
            return False
    except ValueError:
        return False
    if path.suffix.lower() not in _LANGUAGE_BY_EXTENSION:
        return False
    if path.name in _SKIPPED_FILES:
        return False
    relative = path.relative_to(root)
    if any(part in _SKIPPED_DIRS for part in relative.parts[:-1]):
        return False
    if path.name.rfind(".") > 0 and path.suffix.lower() in _BINARY_EXTENSIONS:
        return False
    try:
        return path.stat().st_size <= MAX_FILE_BYTES
    except OSError:
        return False


def _strip_src_layout(parts: list[str]) -> list[str]:
    """Drop ``src``-layout prefixes so module names match import names.

    ``packages/<pkg>/src/<pkg>/...`` (the setuptools src layout used by
    ``packages/veraxi-cli``), a leading ``src/``, and ``<pkg>/src/``
    all address the same importable package without the ``src``
    segment: ``packages/veraxi-cli/src/veraxi/cli/main.py`` is imported
    as ``veraxi.cli.main``, not ``packages.veraxi-cli.src.veraxi...``.
    """
    if len(parts) >= 4 and parts[0] == "packages" and parts[2] == "src":
        return parts[3:]
    if len(parts) >= 2 and parts[0] == "src":
        return parts[1:]
    if len(parts) >= 3 and parts[1] == "src":
        return parts[2:]
    return parts


def _module_qualified_name(relative_path: str) -> str:
    """Dotted module name for a Python file, or path-based name otherwise."""
    suffix = Path(relative_path).suffix.lower()
    stem = relative_path[: -len(suffix)] if suffix else relative_path
    parts = [part for part in stem.replace("\\", "/").split("/") if part]
    parts = _strip_src_layout(parts)
    if suffix == ".py":
        # Python identifiers cannot contain "-": a hyphenated directory
        # on disk is imported with underscores, when it is importable.
        parts = [part.replace("-", "_") for part in parts]
    if parts and parts[-1] == "__init__":
        parts = parts[:-1]
    return ".".join(parts)


# ---------------------------------------------------------------------------
# Python parsing (stdlib ast)
# ---------------------------------------------------------------------------


def _pre_scan_python(
    tree: ast.Module, module_qn: str = ""
) -> tuple[dict[str, tuple[str, str]], dict[str, set[str]]]:
    """Collect definitions in one file before resolving references.

    Returns (module-level definitions by simple name -> (qualified
    suffix, node label), class methods by class qualified name ->
    method names).
    """
    module_defs: dict[str, tuple[str, str]] = {}
    class_methods: dict[str, set[str]] = {}

    def _scan_class(node: ast.ClassDef, prefix: str) -> None:
        class_qn = f"{prefix}.{node.name}" if prefix else node.name
        methods: set[str] = set()
        for child in node.body:
            if isinstance(child, ast.ClassDef):
                _scan_class(child, class_qn)
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                methods.add(child.name)
        class_methods[class_qn] = methods

    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            module_defs[node.name] = (node.name, "Class")
            _scan_class(node, module_qn)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            module_defs[node.name] = (node.name, "Function")
    return module_defs, class_methods


class _PythonFileParser:
    """Parses one Python file into builder nodes/edges."""

    def __init__(
        self,
        builder: _GraphBuilder,
        module_node: CodeNode,
        module_qn: str,
        relative_path: str,
    ) -> None:
        self.builder = builder
        self.module_node = module_node
        self.module_qn = module_qn
        self.relative_path = relative_path
        # simple name -> qualified target for from-imported symbols
        self.imported_symbols: dict[str, str] = {}
        # alias -> module qualified name for `import x.y as alias`
        self.module_aliases: dict[str, str] = {}
        # simple name -> (qualified target, label) for module-level
        # assignment aliases: `public = _private`, `alias = imported`
        self.assignment_aliases: dict[str, tuple[str, str]] = {}
        self.module_defs: dict[str, tuple[str, str]] = {}
        self.class_methods: dict[str, set[str]] = {}

    # -- resolution helpers -------------------------------------------------

    def _resolve_name(self, name: str) -> tuple[str, str] | None:
        """Resolve a simple name to (qualified name, node label)."""
        if name in self.module_defs:
            suffix, label = self.module_defs[name]
            return f"{self.module_qn}.{suffix}", label
        if name in self.assignment_aliases:
            return self.assignment_aliases[name]
        if name in self.imported_symbols:
            # Label is a guess here ("Function"); _GraphBuilder.build()
            # corrects it to the parsed node's label when the target
            # symbol was itself parsed (e.g. an imported class).
            return self.imported_symbols[name], "Function"
        return None

    def _resolve_base(self, expr: ast.expr) -> str | None:
        if isinstance(expr, ast.Name):
            resolved = self._resolve_name(expr.id)
            return resolved[0] if resolved else None
        if isinstance(expr, ast.Attribute) and isinstance(expr.value, ast.Name):
            alias = expr.value.id
            if alias in self.module_aliases:
                return f"{self.module_aliases[alias]}.{expr.attr}"
            if alias in self.imported_symbols:
                return f"{self.imported_symbols[alias]}.{expr.attr}"
        return None

    def _resolve_call(
        self, func: ast.expr, enclosing_class_qn: str | None
    ) -> tuple[str, str] | None:
        """Resolve a call target to (qualified name, node label), or None."""
        if isinstance(func, ast.Name):
            return self._resolve_name(func.id)
        if not isinstance(func, ast.Attribute):
            return None
        if isinstance(func.value, ast.Name) and func.value.id in ("self", "cls"):
            if enclosing_class_qn is None:
                return None
            methods = self.class_methods.get(enclosing_class_qn, set())
            if func.attr in methods:
                return f"{enclosing_class_qn}.{func.attr}", "Function"
            return None
        if isinstance(func.value, ast.Name) and func.value.id in self.module_aliases:
            return f"{self.module_aliases[func.value.id]}.{func.attr}", "Function"
        return None

    # -- AST walking ----------------------------------------------------------

    def parse(self, tree: ast.Module) -> None:
        self.module_defs, self.class_methods = _pre_scan_python(
            tree, self.module_qn
        )
        self._collect_imports(tree)
        self._collect_assignment_aliases(tree)
        for node in tree.body:
            self._visit_top_level(node)

    # -- assignment aliases --------------------------------------------

    def _alias_value_target(self, value: ast.expr) -> tuple[str, str] | None:
        """Resolve the right-hand side of an assignment alias, if simple."""
        if isinstance(value, ast.Name):
            if value.id in self.assignment_aliases:
                return self.assignment_aliases[value.id]
            return self._resolve_name(value.id)
        if isinstance(value, ast.Attribute) and isinstance(value.value, ast.Name):
            alias = value.value.id
            if alias in self.module_aliases:
                return f"{self.module_aliases[alias]}.{value.attr}", "Function"
        return None

    def _collect_assignment_aliases(self, tree: ast.Module) -> None:
        """Record module-level `name = <resolvable symbol>` bindings.

        Iterated to a fixpoint so chained aliases (`b = a` after
        `a = imported`) resolve regardless of statement order. Each
        binding is also registered with the builder under this
        module's qualified name, which is what makes an assignment in
        a package ``__init__`` act as a re-export for other modules.
        """
        pending: list[tuple[str, ast.expr]] = []
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1:
                target = node.targets[0]
                if isinstance(target, ast.Name):
                    pending.append((target.id, node.value))
            elif (
                isinstance(node, ast.AnnAssign)
                and node.value is not None
                and isinstance(node.target, ast.Name)
            ):
                pending.append((node.target.id, node.value))
        changed = True
        while changed:
            changed = False
            remaining: list[tuple[str, ast.expr]] = []
            for name, value in pending:
                if name in self.assignment_aliases or name in self.module_defs:
                    continue
                resolved = self._alias_value_target(value)
                if resolved is None:
                    remaining.append((name, value))
                    continue
                self.assignment_aliases[name] = resolved
                if self.module_qn:
                    self.builder.register_symbol_alias(
                        f"{self.module_qn}.{name}", resolved[0]
                    )
                changed = True
            pending = remaining

    def _collect_imports(self, tree: ast.Module) -> None:
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                self._record_import(node)
            elif isinstance(node, ast.ImportFrom):
                self._record_import_from(node)

    def _record_import(self, node: ast.Import) -> None:
        for alias in node.names:
            self.builder.add_edge(
                "IMPORTS", self.module_node, alias.name, "CodeModule"
            )
            if alias.asname:
                self.module_aliases[alias.asname] = alias.name
            else:
                self.module_aliases[alias.name.split(".")[0]] = alias.name.split(".")[0]

    def _record_import_from(self, node: ast.ImportFrom) -> None:
        target_module = self._import_from_target(node)
        if not target_module:
            return
        self.builder.add_edge(
            "IMPORTS", self.module_node, target_module, "CodeModule"
        )
        for alias in node.names:
            if alias.name == "*":
                continue
            local_name = alias.asname or alias.name
            self.imported_symbols[local_name] = f"{target_module}.{alias.name}"
            # A from-import binds the symbol in this module's namespace,
            # so other modules may reach it through this module (the
            # `__init__` re-export pattern). Register the binding so
            # build() can rewrite edges aimed at the re-export name.
            if self.module_qn:
                self.builder.register_symbol_alias(
                    f"{self.module_qn}.{local_name}",
                    f"{target_module}.{alias.name}",
                )

    def _import_from_target(self, node: ast.ImportFrom) -> str:
        if node.level:
            package_parts = self.module_qn.split(".")
            # For a package __init__ the module qn IS the package; for a
            # plain module the package is its parent.
            if Path(self.relative_path).name == "__init__.py":
                keep = len(package_parts) - node.level + 1
            else:
                keep = len(package_parts) - node.level
            base = package_parts[:keep] if keep > 0 else []
            if node.module:
                base = base + node.module.split(".")
            return ".".join(base)
        return node.module or ""

    def _visit_top_level(self, node: ast.stmt) -> None:
        if isinstance(node, ast.ClassDef):
            self._visit_class(node, self.module_node, self.module_qn)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            self._visit_function(node, self.module_node, self.module_qn, None)
        else:
            self._visit_calls(node, self.module_node, None)

    def _visit_class(
        self, node: ast.ClassDef, container: CodeNode, container_qn: str
    ) -> CodeNode:
        class_qn = f"{container_qn}.{node.name}" if container_qn else node.name
        class_node = self.builder.add_node(
            CodeNode(
                label="Class",
                name=node.name,
                qualified_name=class_qn,
                path=self.relative_path,
                line=node.lineno,
                language="python",
                end_line=node.end_lineno,
            )
        )
        self.builder.add_edge("DEFINES", container, class_qn, "Class")
        for base in node.bases:
            resolved = self._resolve_base(base)
            if resolved is not None:
                self.builder.add_edge("INHERITS", class_node, resolved, "Class")
        for child in node.body:
            if isinstance(child, ast.ClassDef):
                self._visit_class(child, class_node, class_qn)
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                self._visit_function(child, class_node, class_qn, class_qn)
            else:
                self._visit_calls(child, class_node, class_qn)
        return class_node

    def _visit_function(
        self,
        node: ast.FunctionDef | ast.AsyncFunctionDef,
        container: CodeNode,
        container_qn: str,
        enclosing_class_qn: str | None,
    ) -> None:
        func_qn = f"{container_qn}.{node.name}"
        func_node = self.builder.add_node(
            CodeNode(
                label="Function",
                name=node.name,
                qualified_name=func_qn,
                path=self.relative_path,
                line=node.lineno,
                language="python",
                end_line=node.end_lineno,
            )
        )
        self.builder.add_edge("DEFINES", container, func_qn, "Function")
        for child in node.body:
            self._visit_calls(child, func_node, enclosing_class_qn)

    def _visit_calls(
        self, node: ast.AST, caller: CodeNode, enclosing_class_qn: str | None
    ) -> None:
        for child in ast.walk(node):
            if isinstance(child, ast.Call):
                resolved = self._resolve_call(child.func, enclosing_class_qn)
                if resolved is not None:
                    target_qn, target_label = resolved
                    self.builder.add_edge("CALLS", caller, target_qn, target_label)


def _parse_python_file(
    builder: _GraphBuilder,
    file_node: CodeNode,
    module_node: CodeNode,
    path: Path,
    relative_path: str,
) -> None:
    try:
        source = path.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(source, filename=relative_path)
    except (OSError, SyntaxError) as exc:
        logger.warning("Skipping unparseable Python file %s: %s", relative_path, exc)
        return
    parser = _PythonFileParser(builder, module_node, module_node.qualified_name, relative_path)
    parser.parse(tree)


# ---------------------------------------------------------------------------
# Dart / JS / TS parsing (conservative regexes)
# ---------------------------------------------------------------------------

_IMPORT_PATTERNS = (
    re.compile(r"""^\s*import\s+(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]"""),
    re.compile(r"""^\s*export\s+[^'"]*?\s+from\s+['"]([^'"]+)['"]"""),
    re.compile(r"""\brequire\(\s*['"]([^'"]+)['"]\s*\)"""),
)
_CLASS_PATTERN = re.compile(
    r"\bclass\s+([A-Za-z_$][\w$]*)(?:\s+extends\s+([A-Za-z_$][\w$.]*))?"
)
_JS_FUNCTION_PATTERNS = (
    re.compile(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\("),
    re.compile(
        r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?"
        r"(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"
    ),
    re.compile(
        r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?function\b"
    ),
)
# Dart-style declaration: a return-type token, then a name, then "(...) {".
_DART_FUNCTION_PATTERN = re.compile(
    r"^\s*(?:[\w<>\[\],?]+\s+)+([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:async\s*\*?\s*)?\{"
)
_NON_FUNCTION_NAMES = {
    "if", "for", "while", "switch", "catch", "return", "else", "do",
    "class", "import", "export", "new", "throw",
}


# ---------------------------------------------------------------------------
# Tree-sitter multi-language parser (JS/TS, Go, Rust, Java, Dart)
# ---------------------------------------------------------------------------

_TS_CLASS_TYPES = {
    "class_declaration",
    "class_definition",
    "class_specifier",
    "interface_declaration",
    "struct_item",
    "struct_specifier",
    "enum_item",
    "trait_item",
    "mixin_declaration",
    "extension_declaration",
    "class",
    "module",
}
_TS_FUNC_TYPES = {
    "function_declaration",
    "function_definition",
    "method_declaration",
    "method_definition",
    "function_item",
    "function_signature",
    "method_signature",
    "method",
}
_TS_IMPORT_TYPES = {
    "import_statement",
    "import_declaration",
    "import_spec",
    "import_or_export",
    "part_directive",
    "part_of_directive",
    "use_declaration",
    "preproc_include",
    "using_directive",
    "import_header",
}
_TS_CALL_TYPES = {
    "call_expression",
    "method_invocation",
}


def _ts_language_name(path: Path, language: str) -> str:
    if path.suffix.lower() == ".tsx":
        return "tsx"
    return language


def _ts_node_text(node: Any, source: bytes) -> str:
    return source[node.start_byte : node.end_byte].decode("utf-8", errors="replace")


def _ts_child_name(node: Any, source: bytes) -> str | None:
    if node.type == "method_signature":
        for child in node.children:
            if child.type in ("function_signature", "factory_constructor_signature", "getter_signature", "setter_signature"):
                return _ts_child_name(child, source)
    if node.type == "factory_constructor_signature":
        ids = [_ts_node_text(c, source).strip() for c in node.children if c.type == "identifier"]
        return ids[-1] if ids else None
    name_node = node.child_by_field_name("name")
    if name_node is not None:
        return _ts_node_text(name_node, source).strip()
    for child in node.children:
        if child.type in (
            "identifier",
            "simple_identifier",
            "type_identifier",
            "property_identifier",
        ):
            return _ts_node_text(child, source).strip()
    return None


def _ts_extract_superclasses(node: Any, source: bytes) -> list[str]:
    """Extract base class/interface names from heritage/superclass children."""
    bases: list[str] = []
    for child in node.children:
        if child.type in ("type_identifier", "identifier") and node.type in (
            "extends_clause",
            "extends_type_clause",
            "implements_clause",
        ):
            val = _ts_node_text(child, source).strip()
            if val:
                bases.append(val)
        elif child.type in (
            "superclass",
            "class_heritage",
            "extends_clause",
            "extends_type_clause",
            "super_interfaces",
            "mixins",
            "interfaces",
        ):
            for sub in child.children:
                if sub.type in ("type_identifier", "identifier"):
                    val = _ts_node_text(sub, source).strip()
                    if val:
                        bases.append(val)
                elif sub.type in ("extends_clause", "type_identifier", "mixins", "interfaces"):
                    bases.extend(_ts_extract_superclasses(sub, source))
    return bases


def _ts_extract_import_targets(node: Any, source: bytes) -> list[str]:
    targets: list[str] = []
    for child in node.children:
        if child.type in ("string", "string_literal", "interpreted_string_literal", "uri"):
            val = _ts_node_text(child, source).strip().strip("'\"`")
            if val:
                targets.append(val)
        elif child.type == "identifier" and node.type in ("use_declaration", "import_declaration"):
            val = _ts_node_text(child, source).strip()
            if val:
                targets.append(val)
        else:
            targets.extend(_ts_extract_import_targets(child, source))
    return targets


def _ts_extract_call_target(
    node: Any,
    source: bytes,
    defined_funcs: dict[str, str],
    imported_aliases: dict[str, str],
) -> tuple[str, str] | None:
    func_node = node.child_by_field_name("function") or node.child_by_field_name("name")
    if func_node is None and node.children:
        func_node = node.children[0]
    if func_node is None:
        return None
    raw = _ts_node_text(func_node, source).strip()
    if not raw:
        return None
    if raw in defined_funcs:
        return defined_funcs[raw], "Function"
    if "." in raw:
        head, tail = raw.split(".", 1)
        if head in imported_aliases:
            return f"{imported_aliases[head]}.{tail}", "Function"
    return None


@dataclass(frozen=True)
class _DartDirective:
    uri: str
    alias: str | None
    kind: str  # "import" | "export" | "part" | "part_of"


@dataclass(frozen=True)
class _DartPendingCall:
    caller: CodeNode
    enclosing_class_qn: str | None
    receiver: str | None
    name: str


@dataclass
class _DartFileContext:
    relative_path: str
    module_node: CodeNode
    directives: list[_DartDirective] = field(default_factory=list)
    top_defs: dict[str, tuple[str, str]] = field(default_factory=dict)
    classes: dict[str, str] = field(default_factory=dict)
    class_methods: dict[str, dict[str, str]] = field(default_factory=dict)
    pending_calls: list[_DartPendingCall] = field(default_factory=list)
    pending_inherits: list[tuple[CodeNode, str]] = field(default_factory=list)


_DART_PUBSPEC_NAME_RE = re.compile(r"^\s*name\s*:\s*([A-Za-z0-9_]+)\b", re.MULTILINE)


def _discover_dart_package_roots(root_path: Path) -> dict[str, str]:
    """Map Dart package names from ``pubspec.yaml`` to their ``lib`` dir."""
    roots: dict[str, str] = {}
    candidates = [root_path / "pubspec.yaml"]
    try:
        for entry in root_path.iterdir():
            if entry.is_dir() and entry.name not in _SKIPPED_DIRS:
                candidates.append(entry / "pubspec.yaml")
    except OSError:
        pass
    for pubspec in candidates:
        if not pubspec.is_file():
            continue
        try:
            text = pubspec.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        match = _DART_PUBSPEC_NAME_RE.search(text)
        if not match:
            continue
        pkg_name = match.group(1)
        rel_dir = pubspec.parent.relative_to(root_path).as_posix()
        lib_prefix = "lib" if rel_dir == "." else f"{rel_dir}/lib"
        roots.setdefault(pkg_name, lib_prefix)
    return roots


def _resolve_dart_uri(
    uri: str,
    current_rel_path: str,
    package_roots: dict[str, str],
    known_paths: set[str],
) -> str | None:
    """Resolve a Dart import/export/part URI to a parsed repo-relative path."""
    if not uri or uri.startswith("dart:"):
        return None
    if uri.startswith("package:"):
        rest = uri[len("package:") :]
        if "/" not in rest:
            return None
        pkg_name, sub_path = rest.split("/", 1)
        lib_prefix = package_roots.get(pkg_name)
        if lib_prefix is None:
            return None
        candidate = f"{lib_prefix}/{sub_path}"
        return candidate if candidate in known_paths else None
    base_dir = Path(current_rel_path).parent
    joined = (base_dir / uri).as_posix()
    # Normalize '..' segments lexically
    parts: list[str] = []
    for seg in joined.split("/"):
        if not seg or seg == ".":
            continue
        if seg == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(seg)
    candidate = "/".join(parts)
    return candidate if candidate in known_paths else None


def _dart_extract_directive(node: Any, source: bytes) -> _DartDirective | None:
    """Extract a Dart import/export/part directive with optional ``as`` alias."""
    uris = _ts_extract_import_targets(node, source)
    if not uris:
        return None
    uri = uris[0]
    if node.type == "part_directive":
        return _DartDirective(uri=uri, alias=None, kind="part")
    if node.type == "part_of_directive":
        return _DartDirective(uri=uri, alias=None, kind="part_of")
    text = _ts_node_text(node, source)
    kind = "export" if re.search(r"\bexport\b", text) else "import"
    alias_match = re.search(r"\bas\s+([A-Za-z_]\w*)\b", text)
    alias = alias_match.group(1) if alias_match else None
    return _DartDirective(uri=uri, alias=alias, kind=kind)


def _dart_is_arg_selector(node: Any) -> bool:
    return node.type == "selector" and any(c.type == "argument_part" for c in node.children)


def _dart_selector_member(node: Any, source: bytes) -> str | None:
    if node.type != "selector":
        return None
    for child in node.children:
        if child.type in ("unconditional_assignable_selector", "conditional_assignable_selector"):
            for sub in child.children:
                if sub.type == "identifier":
                    return _ts_node_text(sub, source).strip()
    return None


def _dart_collect_calls_in_children(
    children: list[Any],
    source: bytes,
    caller: CodeNode,
    enclosing_class_qn: str | None,
    out: list[_DartPendingCall],
) -> None:
    """Scan sibling AST nodes for ``id(...)``, ``this.m(...)``, ``recv.fn(...)``."""
    idx = 0
    count = len(children)
    while idx < count:
        head = children[idx]
        if head.type in ("identifier", "this") and idx + 1 < count:
            head_text = "this" if head.type == "this" else _ts_node_text(head, source).strip()
            nxt = children[idx + 1]
            if head.type == "identifier" and _dart_is_arg_selector(nxt):
                if head_text not in _NON_FUNCTION_NAMES:
                    out.append(_DartPendingCall(caller, enclosing_class_qn, None, head_text))
                idx += 2
                continue
            member = _dart_selector_member(nxt, source)
            if member and idx + 2 < count and _dart_is_arg_selector(children[idx + 2]):
                out.append(_DartPendingCall(caller, enclosing_class_qn, head_text, member))
                idx += 3
                continue
        idx += 1


def _dart_reachable_files(
    start_path: str,
    contexts: dict[str, _DartFileContext],
    resolved_uris: dict[tuple[str, str], str],
    *,
    include_imports: bool = True,
) -> list[str]:
    """Return parsed Dart file paths reachable via imports/exports/parts."""
    visited: set[str] = {start_path}
    ordered: list[str] = []
    queue: list[tuple[str, bool]] = [(start_path, True)]
    while queue:
        cur_path, allow_imports = queue.pop(0)
        ctx = contexts.get(cur_path)
        if ctx is None:
            continue
        for directive in ctx.directives:
            if directive.kind == "import" and not (include_imports and allow_imports):
                continue
            target_path = resolved_uris.get((cur_path, directive.uri))
            if target_path and target_path not in visited:
                visited.add(target_path)
                ordered.append(target_path)
                # Follow transitive exports and parts, not transitive imports.
                queue.append((target_path, False))
    return ordered


def _dart_find_method(
    class_qn: str,
    method_name: str,
    contexts: dict[str, _DartFileContext],
    resolved_bases: dict[str, list[str]],
) -> str | None:
    """Resolve ``method_name`` on ``class_qn`` or its resolved base classes."""
    seen: set[str] = set()
    queue = [class_qn]
    while queue:
        cur = queue.pop(0)
        if cur in seen:
            continue
        seen.add(cur)
        for ctx in contexts.values():
            methods = ctx.class_methods.get(cur)
            if methods and method_name in methods:
                return methods[method_name]
        queue.extend(resolved_bases.get(cur, ()))
    return None


def _dart_resolve_call(
    call: _DartPendingCall,
    ctx: _DartFileContext,
    contexts: dict[str, _DartFileContext],
    resolved_uris: dict[tuple[str, str], str],
    resolved_bases: dict[str, list[str]],
) -> tuple[str, str] | None:
    """Resolve one Dart call site conservatively; returns (target_qn, label) or None."""
    if call.receiver == "this":
        if not call.enclosing_class_qn:
            return None
        target = _dart_find_method(
            call.enclosing_class_qn, call.name, contexts, resolved_bases
        )
        return (target, "Function") if target else None

    if call.receiver is not None:
        for directive in ctx.directives:
            if directive.kind == "import" and directive.alias == call.receiver:
                target_path = resolved_uris.get((ctx.relative_path, directive.uri))
                if target_path is None:
                    return None
                for cand_path in [target_path, *_dart_reachable_files(target_path, contexts, resolved_uris, include_imports=False)]:
                    cand_ctx = contexts.get(cand_path)
                    if cand_ctx and call.name in cand_ctx.top_defs:
                        return cand_ctx.top_defs[call.name]
                return None
        # Static / factory call: ClassName.method(...)
        class_qn = ctx.classes.get(call.receiver)
        if class_qn is None:
            for rpath in _dart_reachable_files(ctx.relative_path, contexts, resolved_uris):
                rctx = contexts.get(rpath)
                if rctx and call.receiver in rctx.classes:
                    class_qn = rctx.classes[call.receiver]
                    break
        if class_qn:
            target = _dart_find_method(class_qn, call.name, contexts, resolved_bases)
            if target:
                return target, "Function"
        return None

    # Bare call: enclosing class -> same file -> reachable imported/exported/part files
    if call.enclosing_class_qn:
        target = _dart_find_method(
            call.enclosing_class_qn, call.name, contexts, resolved_bases
        )
        if target:
            return target, "Function"
    if call.name in ctx.top_defs:
        return ctx.top_defs[call.name]
    if call.name in ctx.classes:
        return ctx.classes[call.name], "Class"
    for rpath in _dart_reachable_files(ctx.relative_path, contexts, resolved_uris):
        rctx = contexts.get(rpath)
        if rctx is None:
            continue
        if call.name in rctx.top_defs:
            return rctx.top_defs[call.name]
        if call.name in rctx.classes:
            return rctx.classes[call.name], "Class"
    return None


def _resolve_dart_builder(builder: _GraphBuilder) -> None:
    """Resolve cross-file Dart IMPORTS, INHERITS, and CALLS in ``builder``."""
    contexts = builder.dart_contexts
    known_paths = set(contexts)
    resolved_uris: dict[tuple[str, str], str] = {}
    for rel_path, ctx in contexts.items():
        for directive in ctx.directives:
            target = _resolve_dart_uri(
                directive.uri, rel_path, builder.dart_package_roots, known_paths
            )
            if target is not None:
                resolved_uris[(rel_path, directive.uri)] = target
                if directive.kind in ("import", "export"):
                    target_mod_qn = contexts[target].module_node.qualified_name
                    old_key = ("IMPORTS", ctx.module_node.qualified_name, directive.uri)
                    builder.edges.pop(old_key, None)
                    builder.add_edge("IMPORTS", ctx.module_node, target_mod_qn, "CodeModule")

    resolved_bases: dict[str, list[str]] = {}
    for rel_path, ctx in contexts.items():
        reachable = _dart_reachable_files(rel_path, contexts, resolved_uris)
        for class_node, base_name in ctx.pending_inherits:
            base_qn = ctx.classes.get(base_name)
            if base_qn is None:
                for rpath in reachable:
                    rctx = contexts.get(rpath)
                    if rctx and base_name in rctx.classes:
                        base_qn = rctx.classes[base_name]
                        break
            if base_qn is not None:
                old_key = ("INHERITS", class_node.qualified_name, base_name)
                builder.edges.pop(old_key, None)
                builder.add_edge("INHERITS", class_node, base_qn, "Class")
                resolved_bases.setdefault(class_node.qualified_name, []).append(base_qn)

    for ctx in contexts.values():
        for call in ctx.pending_calls:
            resolved = _dart_resolve_call(
                call, ctx, contexts, resolved_uris, resolved_bases
            )
            if resolved is not None:
                target_qn, target_label = resolved
                builder.add_edge("CALLS", call.caller, target_qn, target_label)


@dataclass(frozen=True)
class _TsJsImport:
    specifier: str
    named: dict[str, str]  # local_name -> remote_name
    namespace: str | None = None
    default_alias: str | None = None


@dataclass(frozen=True)
class _TsJsReexport:
    specifier: str
    named: dict[str, str]  # exported_name -> remote_name
    star: bool = False


@dataclass(frozen=True)
class _TsJsPendingCall:
    caller: CodeNode
    enclosing_class_qn: str | None
    receiver: str | None
    name: str
    var_types: dict[str, str]


@dataclass
class _TsJsFileContext:
    relative_path: str
    module_node: CodeNode
    imports: list[_TsJsImport] = field(default_factory=list)
    reexports: list[_TsJsReexport] = field(default_factory=list)
    top_defs: dict[str, tuple[str, str]] = field(default_factory=dict)
    classes: dict[str, str] = field(default_factory=dict)
    class_methods: dict[str, dict[str, str]] = field(default_factory=dict)
    pending_calls: list[_TsJsPendingCall] = field(default_factory=list)
    pending_inherits: list[tuple[CodeNode, str]] = field(default_factory=list)


@dataclass(frozen=True)
class _GoPendingCall:
    caller: CodeNode
    receiver: str | None
    name: str
    var_types: dict[str, str]


@dataclass
class _GoFileContext:
    relative_path: str
    package_dir: str
    module_node: CodeNode
    package_name: str = ""
    imports: dict[str, str] = field(default_factory=dict)
    top_defs: dict[str, tuple[str, str]] = field(default_factory=dict)
    structs: dict[str, str] = field(default_factory=dict)
    struct_methods: dict[str, dict[str, str]] = field(default_factory=dict)
    pending_calls: list[_GoPendingCall] = field(default_factory=list)


_TS_EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs")
_GO_MOD_RE = re.compile(r"^\s*module\s+(\S+)", re.MULTILINE)


def _discover_tsconfig_paths(root_path: Path) -> tuple[str, dict[str, list[str]]]:
    """Read compilerOptions.baseUrl and paths from tsconfig.json/jsconfig.json."""
    for name in ("tsconfig.json", "jsconfig.json"):
        cfg = root_path / name
        if not cfg.is_file():
            continue
        try:
            raw = cfg.read_text(encoding="utf-8", errors="replace")
            cleaned = re.sub(r"//[^\n]*", "", raw)
            data = json.loads(cleaned)
        except (OSError, ValueError) as exc:
            logger.debug("Skipping unreadable %s: %s", name, exc)
            continue
        opts = data.get("compilerOptions") or {}
        if not isinstance(opts, dict):
            continue
        base_url = str(opts.get("baseUrl") or ".").strip().strip("./")
        raw_paths = opts.get("paths") or {}
        paths: dict[str, list[str]] = {}
        if isinstance(raw_paths, dict):
            for pat, targets in raw_paths.items():
                if isinstance(pat, str) and isinstance(targets, list):
                    paths[pat] = [str(t) for t in targets if isinstance(t, str)]
        return base_url, paths
    return "", {}


def _discover_go_module_prefix(root_path: Path) -> str | None:
    """Read the module path from root go.mod, or None."""
    go_mod = root_path / "go.mod"
    if not go_mod.is_file():
        return None
    try:
        text = go_mod.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    m = _GO_MOD_RE.search(text)
    return m.group(1).strip() if m else None


def _probe_ts_candidate(candidate: str, known_paths: set[str]) -> str | None:
    clean = candidate.lstrip("./")
    if clean in known_paths:
        return clean
    for ext in _TS_EXTENSIONS:
        if f"{clean}{ext}" in known_paths:
            return f"{clean}{ext}"
    for ext in _TS_EXTENSIONS:
        if f"{clean}/index{ext}" in known_paths:
            return f"{clean}/index{ext}"
    return None


def _resolve_ts_specifier(
    specifier: str,
    importer_rel: str,
    known_paths: set[str],
    tsconfig: tuple[str, dict[str, list[str]]],
) -> str | None:
    if not specifier:
        return None
    if specifier.startswith("."):
        base_dir = Path(importer_rel).parent
        joined = posixpath.normpath((base_dir / specifier).as_posix())
        return _probe_ts_candidate(joined, known_paths)
    base_url, paths_map = tsconfig
    for pat, targets in paths_map.items():
        if "*" in pat:
            prefix, suffix = pat.split("*", 1)
            if specifier.startswith(prefix) and specifier.endswith(suffix):
                star_val = specifier[len(prefix) : len(specifier) - len(suffix) if suffix else None]
                for target in targets:
                    mapped = target.replace("*", star_val)
                    if base_url:
                        mapped = posixpath.normpath(f"{base_url}/{mapped}")
                    hit = _probe_ts_candidate(mapped, known_paths)
                    if hit:
                        return hit
        elif specifier == pat:
            for target in targets:
                mapped = posixpath.normpath(f"{base_url}/{target}" if base_url else target)
                hit = _probe_ts_candidate(mapped, known_paths)
                if hit:
                    return hit
    return None


def _ts_extract_import_stmt(node: Any, source: bytes) -> _TsJsImport | None:
    specifier = ""
    for child in node.children:
        if child.type in ("string", "string_literal"):
            specifier = _ts_node_text(child, source).strip().strip("'\"`")
    if not specifier:
        return None
    named: dict[str, str] = {}
    namespace: str | None = None
    default_alias: str | None = None
    for child in node.children:
        if child.type != "import_clause":
            continue
        for sub in child.children:
            if sub.type == "identifier":
                default_alias = _ts_node_text(sub, source).strip()
            elif sub.type == "namespace_import":
                ids = [_ts_node_text(c, source).strip() for c in sub.children if c.type == "identifier"]
                if ids:
                    namespace = ids[-1]
            elif sub.type == "named_imports":
                for spec in sub.children:
                    if spec.type != "import_specifier":
                        continue
                    name_n = spec.child_by_field_name("name")
                    alias_n = spec.child_by_field_name("alias")
                    if name_n is not None:
                        remote = _ts_node_text(name_n, source).strip()
                        local = _ts_node_text(alias_n, source).strip() if alias_n is not None else remote
                        named[local] = remote
    return _TsJsImport(specifier=specifier, named=named, namespace=namespace, default_alias=default_alias)


def _ts_extract_export_stmt(node: Any, source: bytes) -> _TsJsReexport | None:
    specifier = ""
    for child in node.children:
        if child.type in ("string", "string_literal"):
            specifier = _ts_node_text(child, source).strip().strip("'\"`")
    if not specifier:
        return None
    named: dict[str, str] = {}
    star = False
    for child in node.children:
        if child.type == "*" or _ts_node_text(child, source).strip() == "*":
            star = True
        elif child.type == "export_clause":
            for spec in child.children:
                if spec.type != "export_specifier":
                    continue
                name_n = spec.child_by_field_name("name")
                alias_n = spec.child_by_field_name("alias")
                if name_n is not None:
                    remote = _ts_node_text(name_n, source).strip()
                    exported = _ts_node_text(alias_n, source).strip() if alias_n is not None else remote
                    named[exported] = remote
    return _TsJsReexport(specifier=specifier, named=named, star=star)


def _ts_lookup_exported(
    file_path: str,
    symbol_name: str,
    contexts: dict[str, _TsJsFileContext],
    tsconfig: tuple[str, dict[str, list[str]]],
    visited: set[tuple[str, str]],
) -> tuple[str, str] | None:
    if (file_path, symbol_name) in visited:
        return None
    visited.add((file_path, symbol_name))
    ctx = contexts.get(file_path)
    if ctx is None:
        return None
    if symbol_name in ctx.top_defs:
        return ctx.top_defs[symbol_name]
    known = set(contexts)
    for reexp in ctx.reexports:
        target_path = _resolve_ts_specifier(reexp.specifier, file_path, known, tsconfig)
        if not target_path:
            continue
        if symbol_name in reexp.named:
            hit = _ts_lookup_exported(target_path, reexp.named[symbol_name], contexts, tsconfig, visited)
            if hit:
                return hit
        if reexp.star:
            hit = _ts_lookup_exported(target_path, symbol_name, contexts, tsconfig, visited)
            if hit:
                return hit
    return None


def _ts_find_method(
    class_qn: str,
    method_name: str,
    contexts: dict[str, _TsJsFileContext],
    resolved_bases: dict[str, list[str]],
    visited: set[str] | None = None,
) -> str | None:
    seen = visited if visited is not None else set()
    if class_qn in seen:
        return None
    seen.add(class_qn)
    for ctx in contexts.values():
        methods = ctx.class_methods.get(class_qn)
        if methods and method_name in methods:
            return methods[method_name]
    for base_qn in resolved_bases.get(class_qn, ()):
        hit = _ts_find_method(base_qn, method_name, contexts, resolved_bases, seen)
        if hit:
            return hit
    return None


def _ts_resolve_symbol_in_ctx(
    ctx: _TsJsFileContext,
    name: str,
    contexts: dict[str, _TsJsFileContext],
    tsconfig: tuple[str, dict[str, list[str]]],
) -> tuple[str, str] | None:
    if name in ctx.top_defs:
        return ctx.top_defs[name]
    known = set(contexts)
    for imp in ctx.imports:
        target_path = _resolve_ts_specifier(imp.specifier, ctx.relative_path, known, tsconfig)
        if not target_path:
            continue
        if name in imp.named:
            hit = _ts_lookup_exported(target_path, imp.named[name], contexts, tsconfig, set())
            if hit:
                return hit
        if name == imp.default_alias:
            hit = _ts_lookup_exported(target_path, "default", contexts, tsconfig, set())
            if hit:
                return hit
    return None


def _resolve_ts_builder(builder: _GraphBuilder) -> None:
    contexts = builder.ts_contexts
    tsconfig = builder.tsconfig_paths
    known = set(contexts)
    for ctx in contexts.values():
        for imp in ctx.imports:
            target_path = _resolve_ts_specifier(imp.specifier, ctx.relative_path, known, tsconfig)
            if target_path and target_path in contexts:
                builder.add_edge("IMPORTS", ctx.module_node, contexts[target_path].module_node.qualified_name, "CodeModule")
        for reexp in ctx.reexports:
            target_path = _resolve_ts_specifier(reexp.specifier, ctx.relative_path, known, tsconfig)
            if target_path and target_path in contexts:
                builder.add_edge("IMPORTS", ctx.module_node, contexts[target_path].module_node.qualified_name, "CodeModule")

    resolved_bases: dict[str, list[str]] = {}
    for ctx in contexts.values():
        for class_node, base_name in ctx.pending_inherits:
            resolved = _ts_resolve_symbol_in_ctx(ctx, base_name, contexts, tsconfig)
            if resolved and resolved[1] == "Class":
                builder.add_edge("INHERITS", class_node, resolved[0], "Class")
                resolved_bases.setdefault(class_node.qualified_name, []).append(resolved[0])

    for ctx in contexts.values():
        for call in ctx.pending_calls:
            target: tuple[str, str] | None = None
            if call.receiver in ("this", "super") and call.enclosing_class_qn:
                m_qn = _ts_find_method(call.enclosing_class_qn, call.name, contexts, resolved_bases)
                if m_qn:
                    target = (m_qn, "Function")
            elif call.receiver and call.receiver in call.var_types:
                cls_name = call.var_types[call.receiver]
                cls_resolved = _ts_resolve_symbol_in_ctx(ctx, cls_name, contexts, tsconfig)
                if cls_resolved and cls_resolved[1] == "Class":
                    m_qn = _ts_find_method(cls_resolved[0], call.name, contexts, resolved_bases)
                    if m_qn:
                        target = (m_qn, "Function")
            elif call.receiver:
                for imp in ctx.imports:
                    if imp.namespace == call.receiver:
                        target_path = _resolve_ts_specifier(imp.specifier, ctx.relative_path, known, tsconfig)
                        if target_path:
                            target = _ts_lookup_exported(target_path, call.name, contexts, tsconfig, set())
                        break
            else:
                target = _ts_resolve_symbol_in_ctx(ctx, call.name, contexts, tsconfig)
                if target is None and call.enclosing_class_qn:
                    m_qn = _ts_find_method(call.enclosing_class_qn, call.name, contexts, resolved_bases)
                    if m_qn:
                        target = (m_qn, "Function")
            if target is not None:
                builder.add_edge("CALLS", call.caller, target[0], target[1])


def _resolve_go_builder(builder: _GraphBuilder) -> None:
    contexts = builder.go_contexts
    by_pkg_dir: dict[str, list[_GoFileContext]] = {}
    for ctx in contexts.values():
        by_pkg_dir.setdefault(ctx.package_dir, []).append(ctx)
    mod_prefix = builder.go_module_prefix

    def _pkg_dir_for_import(import_path: str) -> str | None:
        if mod_prefix and import_path == mod_prefix:
            return "."
        if mod_prefix and import_path.startswith(mod_prefix + "/"):
            return import_path[len(mod_prefix) + 1 :]
        return None

    def _find_in_pkg(pkg_dir: str, sym: str) -> tuple[str, str] | None:
        for fctx in by_pkg_dir.get(pkg_dir, ()):
            if sym in fctx.top_defs:
                return fctx.top_defs[sym]
        return None

    def _find_struct_method(pkg_dir: str, struct_name: str, method_name: str) -> str | None:
        for fctx in by_pkg_dir.get(pkg_dir, ()):
            struct_qn = fctx.structs.get(struct_name)
            if not struct_qn:
                continue
            for mctx in by_pkg_dir.get(pkg_dir, ()):
                methods = mctx.struct_methods.get(struct_qn)
                if methods and method_name in methods:
                    return methods[method_name]
        return None

    for ctx in contexts.values():
        for imp_path in ctx.imports.values():
            pkg_dir = _pkg_dir_for_import(imp_path)
            if pkg_dir and pkg_dir in by_pkg_dir:
                for target_ctx in by_pkg_dir[pkg_dir]:
                    builder.add_edge("IMPORTS", ctx.module_node, target_ctx.module_node.qualified_name, "CodeModule")
        for call in ctx.pending_calls:
            target_qn: str | None = None
            target_label = "Function"
            if call.receiver is None:
                hit = _find_in_pkg(ctx.package_dir, call.name)
                if hit:
                    target_qn, target_label = hit
            elif call.receiver in call.var_types:
                type_ref = call.var_types[call.receiver]
                if "." in type_ref:
                    pkg_alias, struct_name = type_ref.split(".", 1)
                    imp_path = ctx.imports.get(pkg_alias)
                    pkg_dir = _pkg_dir_for_import(imp_path) if imp_path else None
                    if pkg_dir:
                        target_qn = _find_struct_method(pkg_dir, struct_name, call.name)
                else:
                    target_qn = _find_struct_method(ctx.package_dir, type_ref, call.name)
            elif call.receiver in ctx.imports:
                pkg_dir = _pkg_dir_for_import(ctx.imports[call.receiver])
                if pkg_dir:
                    hit = _find_in_pkg(pkg_dir, call.name)
                    if hit:
                        target_qn, target_label = hit
            if target_qn:
                builder.add_edge("CALLS", call.caller, target_qn, target_label)


def _parse_treesitter_file(
    builder: _GraphBuilder,
    module_node: CodeNode,
    path: Path,
    relative_path: str,
    language: str,
) -> bool:
    """Parse non-Python files via tree-sitter; returns False if unavailable."""
    try:
        from tree_sitter_language_pack import get_parser

        parser = get_parser(_ts_language_name(path, language))
        source = path.read_bytes()
    except Exception as exc:
        logger.debug("Tree-sitter unavailable for %s (%s): %s", relative_path, language, exc)
        return False

    tree = parser.parse(source)
    defined_funcs: dict[str, str] = {}
    imported_aliases: dict[str, str] = {}
    pending_calls: list[tuple[CodeNode, Any]] = []
    dart_ctx = (
        _DartFileContext(relative_path=relative_path, module_node=module_node)
        if language == "dart"
        else None
    )
    ts_ctx = (
        _TsJsFileContext(relative_path=relative_path, module_node=module_node)
        if language in ("typescript", "javascript")
        else None
    )
    go_ctx = (
        _GoFileContext(
            relative_path=relative_path,
            package_dir=str(Path(relative_path).parent).replace("\\", "/") or ".",
            module_node=module_node,
        )
        if language == "go"
        else None
    )
    var_types_stack: list[dict[str, str]] = [{}]

    def _current_vars() -> dict[str, str]:
        return var_types_stack[-1]

    def _ts_record_new_var(decl_node: Any) -> None:
        for child in decl_node.children:
            if child.type != "variable_declarator":
                continue
            name_n = child.child_by_field_name("name")
            val_n = child.child_by_field_name("value")
            if name_n is None or val_n is None:
                continue
            vname = _ts_node_text(name_n, source).strip()
            if val_n.type == "new_expression":
                ctor_n = val_n.child_by_field_name("constructor") or (
                    val_n.children[1] if len(val_n.children) > 1 else None
                )
                if ctor_n is not None and vname:
                    _current_vars()[vname] = _ts_node_text(ctor_n, source).strip()

    def _go_record_short_var(node: Any) -> None:
        left_n = node.child_by_field_name("left")
        right_n = node.child_by_field_name("right")
        if left_n is None or right_n is None:
            return
        vname = _ts_node_text(left_n, source).strip().split(",")[0].strip()
        raw_rhs = _ts_node_text(right_n, source).strip()
        m = re.match(r"^&?\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)\s*\{", raw_rhs)
        if m and vname:
            _current_vars()[vname] = m.group(1)

    def _walk_children(
        children: list[Any], container: CodeNode, enclosing_class_qn: str | None
    ) -> None:
        last_func_node: CodeNode | None = None
        for child in children:
            if (
                dart_ctx is not None
                and child.type == "function_body"
                and last_func_node is not None
            ):
                walk(child, last_func_node, enclosing_class_qn)
                last_func_node = None
                continue
            last_func_node = walk(child, container, enclosing_class_qn)

    def walk(
        node: Any, container: CodeNode, enclosing_class_qn: str | None = None
    ) -> CodeNode | None:
        ntype = node.type
        if go_ctx is not None and ntype == "package_clause":
            for child in node.children:
                if child.type == "package_identifier":
                    go_ctx.package_name = _ts_node_text(child, source).strip()
            return None

        if go_ctx is not None and ntype == "import_spec":
            alias: str | None = None
            imp_path = ""
            for child in node.children:
                if child.type == "package_identifier":
                    alias = _ts_node_text(child, source).strip()
                elif child.type == "interpreted_string_literal":
                    imp_path = _ts_node_text(child, source).strip().strip('"')
            if imp_path:
                pkg_alias = alias or imp_path.rsplit("/", 1)[-1]
                go_ctx.imports[pkg_alias] = imp_path
                builder.add_edge("IMPORTS", module_node, imp_path, "CodeModule")
            return None

        if go_ctx is not None and ntype == "type_spec":
            name_n = node.child_by_field_name("name")
            type_n = node.child_by_field_name("type")
            if name_n is not None and type_n is not None and type_n.type == "struct_type":
                sname = _ts_node_text(name_n, source).strip()
                if sname:
                    sqn = f"{container.qualified_name}.{sname}"
                    snode = builder.add_node(
                        CodeNode(
                            label="Class",
                            name=sname,
                            qualified_name=sqn,
                            path=relative_path,
                            line=node.start_point[0] + 1,
                            language=language,
                            end_line=node.end_point[0] + 1,
                        )
                    )
                    builder.add_edge("DEFINES", container, sqn, "Class")
                    go_ctx.structs[sname] = sqn
                    go_ctx.top_defs[sname] = (sqn, "Class")
                    go_ctx.struct_methods.setdefault(sqn, {})
                    return snode
            return None

        if go_ctx is not None and ntype == "method_declaration":
            recv_n = node.child_by_field_name("receiver")
            name_n = node.child_by_field_name("name")
            if recv_n is not None and name_n is not None:
                mname = _ts_node_text(name_n, source).strip()
                recv_text = _ts_node_text(recv_n, source)
                m = re.search(r"\*?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)$", recv_text.strip())
                struct_name = m.group(1) if m else ""
                recv_var_m = re.match(r"^\(\s*([A-Za-z_][A-Za-z0-9_]*)\s+", recv_text.strip())
                recv_var = recv_var_m.group(1) if recv_var_m else ""
                if struct_name and mname:
                    struct_qn = go_ctx.structs.get(struct_name) or f"{module_node.qualified_name}.{struct_name}"
                    func_qn = f"{struct_qn}.{mname}"
                    func_node = builder.add_node(
                        CodeNode(
                            label="Function",
                            name=mname,
                            qualified_name=func_qn,
                            path=relative_path,
                            line=node.start_point[0] + 1,
                            language=language,
                            end_line=node.end_point[0] + 1,
                        )
                    )
                    builder.add_edge("DEFINES", module_node, func_qn, "Function")
                    go_ctx.struct_methods.setdefault(struct_qn, {})[mname] = func_qn
                    var_types_stack.append({recv_var: struct_name} if recv_var else {})
                    _walk_children(node.children, func_node, struct_qn)
                    var_types_stack.pop()
                    return func_node

        if go_ctx is not None and ntype == "short_var_declaration":
            _go_record_short_var(node)

        if ts_ctx is not None and ntype == "export_statement":
            reexp = _ts_extract_export_stmt(node, source)
            if reexp is not None:
                ts_ctx.reexports.append(reexp)
                builder.add_edge("IMPORTS", module_node, reexp.specifier, "CodeModule")
                return None

        if ts_ctx is not None and ntype in ("lexical_declaration", "variable_declaration"):
            if container.label == "Function":
                _ts_record_new_var(node)
            for child in node.children:
                if child.type != "variable_declarator":
                    continue
                name_n = child.child_by_field_name("name")
                val_n = child.child_by_field_name("value")
                if name_n is not None and val_n is not None and val_n.type in ("arrow_function", "function_expression"):
                    fname = _ts_node_text(name_n, source).strip()
                    if fname and fname not in _NON_FUNCTION_NAMES:
                        func_qn = f"{container.qualified_name}.{fname}"
                        func_node = builder.add_node(
                            CodeNode(
                                label="Function",
                                name=fname,
                                qualified_name=func_qn,
                                path=relative_path,
                                line=node.start_point[0] + 1,
                                language=language,
                                end_line=node.end_point[0] + 1,
                            )
                        )
                        builder.add_edge("DEFINES", container, func_qn, "Function")
                        defined_funcs[fname] = func_qn
                        ts_ctx.top_defs[fname] = (func_qn, "Function")
                        var_types_stack.append({})
                        _walk_children(val_n.children, func_node, enclosing_class_qn)
                        var_types_stack.pop()
                        return func_node

        if ntype in _TS_IMPORT_TYPES:
            if dart_ctx is not None:
                directive = _dart_extract_directive(node, source)
                if directive is not None:
                    dart_ctx.directives.append(directive)
                    if directive.kind in ("import", "export"):
                        builder.add_edge("IMPORTS", module_node, directive.uri, "CodeModule")
                return None
            if ts_ctx is not None:
                imp = _ts_extract_import_stmt(node, source)
                if imp is not None:
                    ts_ctx.imports.append(imp)
                    builder.add_edge("IMPORTS", module_node, imp.specifier, "CodeModule")
                return None
            if go_ctx is not None:
                _walk_children(node.children, container, enclosing_class_qn)
                return None
            for target in _ts_extract_import_targets(node, source):
                builder.add_edge("IMPORTS", module_node, target, "CodeModule")
                alias = target.rsplit("/", 1)[-1].rsplit(".", 1)[-1]
                if alias:
                    imported_aliases[alias] = target
            return None

        if ntype in _TS_CLASS_TYPES:
            name = _ts_child_name(node, source)
            if name:
                class_qn = f"{container.qualified_name}.{name}"
                class_node = builder.add_node(
                    CodeNode(
                        label="Class",
                        name=name,
                        qualified_name=class_qn,
                        path=relative_path,
                        line=node.start_point[0] + 1,
                        language=language,
                        end_line=node.end_point[0] + 1,
                    )
                )
                builder.add_edge("DEFINES", container, class_qn, "Class")
                if dart_ctx is not None:
                    dart_ctx.classes[name] = class_qn
                    dart_ctx.class_methods.setdefault(class_qn, {})
                if ts_ctx is not None:
                    ts_ctx.classes[name] = class_qn
                    ts_ctx.top_defs[name] = (class_qn, "Class")
                    ts_ctx.class_methods.setdefault(class_qn, {})
                for base in _ts_extract_superclasses(node, source):
                    if ts_ctx is not None:
                        ts_ctx.pending_inherits.append((class_node, base))
                    else:
                        builder.add_edge("INHERITS", class_node, base, "Class")
                        if dart_ctx is not None:
                            dart_ctx.pending_inherits.append((class_node, base))
                _walk_children(node.children, class_node, class_qn)
                return None

        if ntype in _TS_FUNC_TYPES:
            name = _ts_child_name(node, source)
            if name and name not in _NON_FUNCTION_NAMES:
                func_qn = f"{container.qualified_name}.{name}"
                func_node = builder.add_node(
                    CodeNode(
                        label="Function",
                        name=name,
                        qualified_name=func_qn,
                        path=relative_path,
                        line=node.start_point[0] + 1,
                        language=language,
                        end_line=node.end_point[0] + 1,
                    )
                )
                builder.add_edge("DEFINES", container, func_qn, "Function")
                defined_funcs[name] = func_qn
                if dart_ctx is not None:
                    if container.label == "Class":
                        dart_ctx.class_methods.setdefault(container.qualified_name, {})[name] = func_qn
                    else:
                        dart_ctx.top_defs[name] = (func_qn, "Function")
                    # Dart's function_body is a sibling of method_signature /
                    # function_signature, not a child; recursing here would
                    # visit function_signature inside method_signature twice.
                    return func_node
                if ts_ctx is not None:
                    if container.label == "Class":
                        ts_ctx.class_methods.setdefault(container.qualified_name, {})[name] = func_qn
                    else:
                        ts_ctx.top_defs[name] = (func_qn, "Function")
                if go_ctx is not None:
                    go_ctx.top_defs[name] = (func_qn, "Function")
                var_types_stack.append({})
                _walk_children(node.children, func_node, enclosing_class_qn)
                var_types_stack.pop()
                return func_node

        if dart_ctx is not None and container.label == "Function":
            _dart_collect_calls_in_children(
                node.children, source, container, enclosing_class_qn, dart_ctx.pending_calls
            )
        elif ts_ctx is not None and ntype in _TS_CALL_TYPES and container.label == "Function":
            fn_node = node.child_by_field_name("function") or (node.children[0] if node.children else None)
            if fn_node is not None:
                raw_fn = _ts_node_text(fn_node, source).strip()
                if "." in raw_fn:
                    recv, cname = raw_fn.rsplit(".", 1)
                    ts_ctx.pending_calls.append(
                        _TsJsPendingCall(container, enclosing_class_qn, recv.strip(), cname.strip(), dict(_current_vars()))
                    )
                elif raw_fn:
                    ts_ctx.pending_calls.append(
                        _TsJsPendingCall(container, enclosing_class_qn, None, raw_fn, dict(_current_vars()))
                    )
        elif go_ctx is not None and ntype in _TS_CALL_TYPES and container.label == "Function":
            fn_node = node.child_by_field_name("function") or (node.children[0] if node.children else None)
            if fn_node is not None:
                raw_fn = _ts_node_text(fn_node, source).strip()
                if "." in raw_fn:
                    recv, cname = raw_fn.rsplit(".", 1)
                    go_ctx.pending_calls.append(
                        _GoPendingCall(container, recv.strip(), cname.strip(), dict(_current_vars()))
                    )
                elif raw_fn:
                    go_ctx.pending_calls.append(
                        _GoPendingCall(container, None, raw_fn, dict(_current_vars()))
                    )
        elif ntype in _TS_CALL_TYPES and container.label == "Function":
            pending_calls.append((container, node))

        _walk_children(node.children, container, enclosing_class_qn)
        return None

    walk(tree.root_node, module_node, None)
    if dart_ctx is not None:
        builder.dart_contexts[relative_path] = dart_ctx
    if ts_ctx is not None:
        builder.ts_contexts[relative_path] = ts_ctx
    if go_ctx is not None:
        builder.go_contexts[relative_path] = go_ctx
    for caller_node, call_node in pending_calls:
        resolved = _ts_extract_call_target(
            call_node, source, defined_funcs, imported_aliases
        )
        if resolved is not None:
            target_qn, target_label = resolved
            builder.add_edge("CALLS", caller_node, target_qn, target_label)
    return True


def _parse_declared_file(
    builder: _GraphBuilder,
    file_node: CodeNode,
    module_node: CodeNode,
    path: Path,
    relative_path: str,
    language: str,
) -> None:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        logger.warning("Skipping unreadable file %s: %s", relative_path, exc)
        return
    module_qn = module_node.qualified_name
    defined_classes: dict[str, str] = {}
    # (class node, brace depth at which its body closes) stack
    class_stack: list[tuple[CodeNode, int]] = []
    depth = 0
    for lineno, line in enumerate(lines, start=1):
        while class_stack and depth < class_stack[-1][1]:
            class_stack.pop()
        _record_declared_imports(builder, module_node, line)
        class_match = _CLASS_PATTERN.search(line)
        if class_match:
            depth = _handle_declared_class(
                builder, module_node, module_qn, relative_path, language,
                class_match, lineno, line, depth, class_stack, defined_classes,
            )
            continue
        _record_declared_function(
            builder, module_node, module_qn, relative_path, language,
            line, lineno, class_stack,
        )
        depth += line.count("{") - line.count("}")


def _record_declared_imports(
    builder: _GraphBuilder, module_node: CodeNode, line: str
) -> None:
    for pattern in _IMPORT_PATTERNS:
        match = pattern.search(line)
        if match:
            builder.add_edge("IMPORTS", module_node, match.group(1), "CodeModule")
            return


def _handle_declared_class(
    builder: _GraphBuilder,
    module_node: CodeNode,
    module_qn: str,
    relative_path: str,
    language: str,
    match: re.Match[str],
    lineno: int,
    line: str,
    depth: int,
    class_stack: list[tuple[CodeNode, int]],
    defined_classes: dict[str, str],
) -> int:
    name, base = match.group(1), match.group(2)
    class_qn = f"{module_qn}.{name}"
    class_node = builder.add_node(
        CodeNode(
            label="Class",
            name=name,
            qualified_name=class_qn,
            path=relative_path,
            line=lineno,
            language=language,
        )
    )
    builder.add_edge("DEFINES", module_node, class_qn, "Class")
    defined_classes[name] = class_qn
    if base:
        target = defined_classes.get(base.split(".")[-1], base)
        builder.add_edge("INHERITS", class_node, target, "Class")
    depth += line.count("{") - line.count("}")
    if "{" in line:
        class_stack.append((class_node, depth))
    return depth


def _record_declared_function(
    builder: _GraphBuilder,
    module_node: CodeNode,
    module_qn: str,
    relative_path: str,
    language: str,
    line: str,
    lineno: int,
    class_stack: list[tuple[CodeNode, int]],
) -> None:
    name = _declared_function_name(line, language)
    if name is None:
        return
    container = class_stack[-1][0] if class_stack else module_node
    func_qn = f"{container.qualified_name}.{name}"
    builder.add_node(
        CodeNode(
            label="Function",
            name=name,
            qualified_name=func_qn,
            path=relative_path,
            line=lineno,
            language=language,
        )
    )
    builder.add_edge("DEFINES", container, func_qn, "Function")


def _declared_function_name(line: str, language: str) -> str | None:
    for pattern in _JS_FUNCTION_PATTERNS:
        match = pattern.search(line)
        if match and match.group(1) not in _NON_FUNCTION_NAMES:
            return match.group(1)
    if language == "dart":
        match = _DART_FUNCTION_PATTERN.match(line)
        if match and match.group(1) not in _NON_FUNCTION_NAMES:
            return match.group(1)
    return None


# ---------------------------------------------------------------------------
# Repo walking / public parse entry point
# ---------------------------------------------------------------------------


def _parse_one_file(builder: _GraphBuilder, root_path: Path, path: Path) -> None:
    """Parse a single file into ``builder`` (file + module nodes, edges).

    Shared by :func:`parse_repo` (every file in the tree) and
    :func:`parse_files` (an explicit subset, for incremental updates),
    so both produce identical nodes/edges for the same file content.
    The caller guarantees ``path`` passed :func:`_is_parseable_file`.
    """
    relative_path = path.relative_to(root_path).as_posix()
    language = _LANGUAGE_BY_EXTENSION[path.suffix.lower()]
    module_qn = _module_qualified_name(relative_path)
    file_node = builder.add_node(
        CodeNode(
            label="CodeFile",
            name=path.name,
            qualified_name=relative_path,
            path=relative_path,
            line=1,
            language=language,
        )
    )
    module_node = builder.add_node(
        CodeNode(
            label="CodeModule",
            name=module_qn.rsplit(".", 1)[-1] if module_qn else path.stem,
            qualified_name=module_qn,
            path=relative_path,
            line=1,
            language=language,
        )
    )
    builder.add_edge("DEFINES", file_node, module_qn, "CodeModule")
    if language == "python":
        _parse_python_file(builder, file_node, module_node, path, relative_path)
    elif not _parse_treesitter_file(
        builder, module_node, path, relative_path, language
    ):
        _parse_declared_file(
            builder, file_node, module_node, path, relative_path, language
        )


ProgressCallback = Callable[[str, str], None]

_SHARD_PARSE_THRESHOLD = 200


def collect_parseable_files(root_path: Path) -> list[Path]:
    """Return sorted parseable source files under ``root_path``."""
    if not root_path.is_dir():
        return []
    return [
        path
        for path in sorted(root_path.rglob("*"))
        if path.is_file() and _is_parseable_file(path, root_path)
    ]


def _emit_parse_progress(
    progress_callback: ProgressCallback | None,
    done: int,
    total: int,
) -> None:
    if progress_callback is None or total <= 0:
        return
    step = max(1, total // 20)
    if done == 1 or done == total or done % step == 0:
        progress_callback("parsing", f"Parsing {done}/{total} files…")


def _parse_shard_builder(
    root_path: Path, files: list[Path], repo_key: str
) -> _GraphBuilder:
    builder = _GraphBuilder(repo_key=repo_key)
    for path in files:
        _parse_one_file(builder, root_path, path)
    return builder


def _parse_shard(
    root_path: Path, files: list[Path], repo_key: str
) -> CodeGraph:
    builder = _parse_shard_builder(root_path, files, repo_key)
    builder.dart_package_roots = _discover_dart_package_roots(root_path)
    builder.tsconfig_paths = _discover_tsconfig_paths(root_path)
    builder.go_module_prefix = _discover_go_module_prefix(root_path)
    builder.tsconfig_paths = _discover_tsconfig_paths(root_path)
    builder.go_module_prefix = _discover_go_module_prefix(root_path)
    return builder.build()


def _merge_shard_builders(
    builders: list[_GraphBuilder],
    repo_key: str,
    dart_package_roots: dict[str, str],
    tsconfig_paths: tuple[str, dict[str, list[str]]] = ("", {}),
    go_module_prefix: str | None = None,
) -> CodeGraph:
    merged = _GraphBuilder(repo_key=repo_key)
    merged.dart_package_roots = dart_package_roots
    merged.tsconfig_paths = tsconfig_paths
    merged.go_module_prefix = go_module_prefix
    for shard in builders:
        for node in shard.nodes.values():
            merged.add_node(node)
        for key, edge in shard.edges.items():
            merged.edges.setdefault(key, edge)
        merged.symbol_aliases.update(shard.symbol_aliases)
        merged.dart_contexts.update(shard.dart_contexts)
        merged.ts_contexts.update(shard.ts_contexts)
        merged.go_contexts.update(shard.go_contexts)
    return merged.build()


def parse_repo(
    root: str | Path,
    repo_key: str | None = None,
    progress_callback: ProgressCallback | None = None,
) -> CodeGraph:
    """Parse the repo tree at ``root`` into an in-memory :class:`CodeGraph`.

    Pure: no database or network access. Paths on nodes are relative to
    ``root`` (POSIX separators) so results are machine-independent.
    Every node/edge is stamped with ``repo_key`` — derived from
    ``root`` via :func:`derive_repo_key` when not given (that probe
    reads the checkout's local git config only).
    """
    root_path = Path(os.path.realpath(root))
    resolved_key = derive_repo_key(root_path) if repo_key is None else repo_key
    files = collect_parseable_files(root_path)
    total = len(files)
    if total == 0:
        return _GraphBuilder(repo_key=resolved_key).build()

    dart_package_roots = _discover_dart_package_roots(root_path)
    tsconfig_paths = _discover_tsconfig_paths(root_path)
    go_module_prefix = _discover_go_module_prefix(root_path)
    if total >= _SHARD_PARSE_THRESHOLD:
        workers = min(4, os.cpu_count() or 2)
        chunk_size = max(1, (total + workers - 1) // workers)
        shards_input = [
            files[i : i + chunk_size] for i in range(0, total, chunk_size)
        ]
        _emit_parse_progress(progress_callback, 1, total)
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [
                pool.submit(_parse_shard_builder, root_path, shard, resolved_key)
                for shard in shards_input
            ]
            shard_builders: list[_GraphBuilder] = []
            completed_files = 0
            for shard, fut in zip(shards_input, futures, strict=True):
                shard_builders.append(fut.result())
                completed_files += len(shard)
                _emit_parse_progress(progress_callback, completed_files, total)
        return _merge_shard_builders(
            shard_builders, resolved_key, dart_package_roots, tsconfig_paths, go_module_prefix
        )

    builder = _GraphBuilder(repo_key=resolved_key)
    builder.dart_package_roots = dart_package_roots
    builder.tsconfig_paths = tsconfig_paths
    builder.go_module_prefix = go_module_prefix
    for idx, path in enumerate(files, 1):
        _parse_one_file(builder, root_path, path)
        _emit_parse_progress(progress_callback, idx, total)
    return builder.build()


def parse_files(
    root: str | Path,
    relative_paths: list[str],
    known_target_labels: dict[str, str] | None = None,
    repo_key: str | None = None,
) -> CodeGraph:
    """Parse exactly ``relative_paths`` of the repo at ``root``.

    The per-file counterpart of :func:`parse_repo`, used by the
    incremental updater: paths that are missing (deleted files) or no
    longer parseable are skipped, so the result holds only the nodes
    and edges the listed files currently produce. ``known_target_labels``
    seeds edge target-label correction with the labels of nodes that
    exist outside this subset (see :class:`_GraphBuilder`).
    """
    root_path = Path(os.path.realpath(root))
    builder = _GraphBuilder(
        known_target_labels=known_target_labels,
        repo_key=derive_repo_key(root_path) if repo_key is None else repo_key,
    )
    builder.dart_package_roots = _discover_dart_package_roots(root_path)
    builder.tsconfig_paths = _discover_tsconfig_paths(root_path)
    builder.go_module_prefix = _discover_go_module_prefix(root_path)
    if not root_path.is_dir():
        return builder.build()
    for relative_path in relative_paths:
        path = root_path / relative_path
        if not path.is_file() or not _is_parseable_file(path, root_path):
            continue
        _parse_one_file(builder, root_path, path)
    return builder.build()


# ---------------------------------------------------------------------------
# Neo4j writer (graph_write.py patterns: tenant-scoped, parameterized)
# ---------------------------------------------------------------------------


def _key_identifier(repo_key: str, qualified_name: str) -> str:
    """Identifier segment of a code node's structural key.

    Namespaced by repo — ``<repo_key>::<qualified_name>`` — so two
    repos in one tenant never share a node identity. An empty
    ``repo_key`` (a graph built by hand, outside every ingestion
    path) keeps the historical un-namespaced identifier.
    """
    return f"{repo_key}::{qualified_name}" if repo_key else qualified_name


def _write_node(client: Any, node: CodeNode, tenant_id: str) -> None:
    from backend.ingestion.graph_write import structural_key, upsert_structural_node

    upsert_structural_node(
        client,
        label=node.label,
        allowed_labels=NODE_LABELS,
        key_field="code_key",
        key_value=structural_key(
            tenant_id, node.label, _key_identifier(node.repo_key, node.qualified_name)
        ),
        properties=node.properties(tenant_id),
    )


def _write_placeholder_node(
    client: Any,
    edge: CodeEdge,
    tenant_id: str,
    parsed_keys: set[tuple[str, str, str]],
) -> None:
    """Create a bare node for a resolved target outside the parsed tree."""
    if (edge.repo_key, edge.target_label, edge.target_qn) in parsed_keys:
        return
    if edge.target_label not in NODE_LABELS:
        return
    name = edge.target_qn.rsplit(".", 1)[-1].rsplit("/", 1)[-1]
    placeholder = CodeNode(
        label=edge.target_label,
        name=name,
        qualified_name=edge.target_qn,
        path="",
        line=0,
        language="",
        resolved=False,
        repo_key=edge.repo_key,
    )
    _write_node(client, placeholder, tenant_id)


def _write_edge(client: Any, edge: CodeEdge, tenant_id: str) -> None:
    from backend.ingestion.graph_write import structural_key, upsert_structural_edge

    upsert_structural_edge(
        client,
        edge_type=edge.type,
        allowed_edge_types=EDGE_TYPES,
        key_field="code_key",
        from_key=structural_key(
            tenant_id, edge.source_label, _key_identifier(edge.repo_key, edge.source_qn)
        ),
        to_key=structural_key(
            tenant_id, edge.target_label, _key_identifier(edge.repo_key, edge.target_qn)
        ),
        tenant_id=tenant_id,
    )


_BATCH_WRITE_THRESHOLD = 100


def _collect_placeholder_nodes(
    edges: list[CodeEdge],
    parsed_keys: set[tuple[str, str, str]],
) -> list[CodeNode]:
    """Deduplicate bare placeholder nodes for resolved targets outside the parsed tree."""
    seen: set[tuple[str, str, str]] = set()
    placeholders: list[CodeNode] = []
    for edge in edges:
        key = (edge.repo_key, edge.target_label, edge.target_qn)
        if key in parsed_keys or key in seen or edge.target_label not in NODE_LABELS:
            continue
        seen.add(key)
        name = edge.target_qn.rsplit(".", 1)[-1].rsplit("/", 1)[-1]
        placeholders.append(
            CodeNode(
                label=edge.target_label,
                name=name,
                qualified_name=edge.target_qn,
                path="",
                line=0,
                language="",
                resolved=False,
                repo_key=edge.repo_key,
            )
        )
    return placeholders


def _write_code_graph_batched(
    client: Any,
    graph: CodeGraph,
    placeholders: list[CodeNode],
    tenant_id: str,
    progress_callback: ProgressCallback | None = None,
) -> None:
    """Persist nodes and edges in UNWIND batches grouped by label/edge type."""
    from backend.ingestion.graph_write import (
        structural_key,
        upsert_structural_edges_batch,
        upsert_structural_nodes_batch,
    )

    nodes_by_label: dict[str, list[dict[str, Any]]] = {}
    for node in (*graph.nodes, *placeholders):
        key = structural_key(
            tenant_id, node.label, _key_identifier(node.repo_key, node.qualified_name)
        )
        props = node.properties(tenant_id)
        props["code_key"] = key
        nodes_by_label.setdefault(node.label, []).append(
            {"key": key, "properties": props}
        )

    total_nodes = sum(len(rows) for rows in nodes_by_label.values())
    written_nodes = 0
    for label, rows in nodes_by_label.items():
        upsert_structural_nodes_batch(
            client,
            label=label,
            allowed_labels=NODE_LABELS,
            key_field="code_key",
            rows=rows,
        )
        written_nodes += len(rows)
        if progress_callback is not None and total_nodes > 0:
            progress_callback(
                "writing_graph", f"Writing graph ({written_nodes}/{total_nodes} nodes)…"
            )

    edges_by_type: dict[str, list[dict[str, Any]]] = {}
    for edge in graph.edges:
        edges_by_type.setdefault(edge.type, []).append(
            {
                "from_key": structural_key(
                    tenant_id,
                    edge.source_label,
                    _key_identifier(edge.repo_key, edge.source_qn),
                ),
                "to_key": structural_key(
                    tenant_id,
                    edge.target_label,
                    _key_identifier(edge.repo_key, edge.target_qn),
                ),
            }
        )

    total_edges = sum(len(rows) for rows in edges_by_type.values())
    written_edges = 0
    for edge_type, rows in edges_by_type.items():
        upsert_structural_edges_batch(
            client,
            edge_type=edge_type,
            allowed_edge_types=EDGE_TYPES,
            key_field="code_key",
            rows=rows,
            tenant_id=tenant_id,
        )
        written_edges += len(rows)
        if progress_callback is not None and total_edges > 0:
            progress_callback(
                "writing_graph", f"Linking edges ({written_edges}/{total_edges})…"
            )


def write_code_graph(
    client: Any,
    graph: CodeGraph,
    tenant_id: str = "default",
    progress_callback: ProgressCallback | None = None,
) -> dict[str, int]:
    """Persist a parsed :class:`CodeGraph` to Neo4j via ``client``.

    ``client`` is the existing Neo4j storage client (anything exposing
    ``execute_write(query, parameters)``, e.g. ``Neo4jStorageClient``).
    Every query is parameterized; labels/relationship types are
    interpolated only from this module's whitelists. Code nodes carry
    no Qdrant point ID (see module docstring). Returns write counts.
    """
    parsed_keys = {node.key for node in graph.nodes}
    if len(graph.nodes) + len(graph.edges) >= _BATCH_WRITE_THRESHOLD:
        placeholders = _collect_placeholder_nodes(graph.edges, parsed_keys)
        _write_code_graph_batched(
            client, graph, placeholders, tenant_id, progress_callback=progress_callback
        )
        return {"nodes_written": len(graph.nodes), "edges_written": len(graph.edges)}

    for node in graph.nodes:
        _write_node(client, node, tenant_id)
    for edge in graph.edges:
        _write_placeholder_node(client, edge, tenant_id, parsed_keys)
    for edge in graph.edges:
        _write_edge(client, edge, tenant_id)
    return {"nodes_written": len(graph.nodes), "edges_written": len(graph.edges)}


MAX_INGEST_NODES = 200_000
MAX_INGEST_EDGES = 500_000


def graph_from_payload(
    nodes: list[dict[str, Any]],
    edges: list[dict[str, Any]],
    repo_key: str = "",
) -> CodeGraph:
    """Build a :class:`CodeGraph` from a pre-parsed payload.

    Used by ``POST /api/v1/code/ingest-graph``: a client (the CLI's
    ``xray index --local``) parses a repo it can read and uploads the
    graph, so the server needs no filesystem access to that repo.
    Labels / edge types are validated against this module's whitelists;
    anything else is dropped (fail closed). ``resolved`` defaults to
    True and is only False for client-marked external placeholders.
    The whole payload is one repo: every node and edge is stamped
    with ``repo_key`` (the payload's repo identity, supplied by the
    caller — see :func:`write_parsed_code_graph`).
    """
    parsed_nodes: list[CodeNode] = []
    seen: set[tuple[str, str]] = set()
    for raw in nodes or []:
        label = raw.get("label")
        qualified_name = raw.get("qualified_name")
        if label not in NODE_LABELS or not qualified_name:
            continue
        key = (label, str(qualified_name))
        if key in seen:
            continue
        seen.add(key)
        parsed_nodes.append(
            CodeNode(
                label=label,
                name=str(raw.get("name") or str(qualified_name).rsplit(".", 1)[-1]),
                qualified_name=str(qualified_name),
                path=str(raw.get("path") or ""),
                line=int(raw.get("line") or 0),
                language=str(raw.get("language") or ""),
                resolved=bool(raw.get("resolved", True)),
                end_line=(
                    int(raw["end_line"])
                    if isinstance(raw.get("end_line"), int)
                    and raw["end_line"] > 0
                    else None
                ),
                repo_key=repo_key,
                resolution=(
                    str(raw["resolution"])
                    if raw.get("resolution") in ("scip", "heuristic")
                    else "heuristic"
                ),
            )
        )
    parsed_edges: list[CodeEdge] = []
    for raw in edges or []:
        edge_type = raw.get("type")
        if edge_type not in EDGE_TYPES:
            continue
        if not raw.get("source_qn") or not raw.get("target_qn"):
            continue
        if raw.get("source_label") not in NODE_LABELS:
            continue
        if raw.get("target_label") not in NODE_LABELS:
            continue
        parsed_edges.append(
            CodeEdge(
                type=edge_type,
                source_qn=str(raw["source_qn"]),
                source_label=str(raw["source_label"]),
                target_qn=str(raw["target_qn"]),
                target_label=str(raw["target_label"]),
                repo_key=repo_key,
            )
        )
    return CodeGraph(nodes=parsed_nodes, edges=parsed_edges)


def write_parsed_code_graph(
    client: Any,
    nodes: list[dict[str, Any]],
    edges: list[dict[str, Any]],
    tenant_id: str = "default",
    repo_name: str | None = None,
    source_commit: str | None = None,
) -> dict[str, int]:
    """Persist a pre-parsed graph payload (see :func:`graph_from_payload`).

    Stamps the index metadata (see :func:`write_index_meta`) with the
    client-reported ``repo_name`` / ``source_commit``: the parsing
    client runs where the repo lives, so its git HEAD is the honest
    provenance; the server never invents one. Both default to unknown.
    The ``repo_name`` is also the graph's repo key: an uploaded graph
    has no server-side checkout to derive one from, so the payload's
    own repo identity namespaces its nodes (defaulting to the single
    ``"uploaded-graph"`` bucket when the client reports none).
    """
    repo_key = repo_name or "uploaded-graph"
    graph = graph_from_payload(nodes, edges, repo_key=repo_key)
    counts = write_code_graph(client, graph, tenant_id=tenant_id)
    write_index_meta(
        client,
        tenant_id,
        repo_key=repo_key,
        repo_root="",
        source_commit=source_commit,
        kind="upload",
    )
    return counts


_STREAMING_FILE_THRESHOLD = 2000
_STREAMING_SHARD_SIZE = 500


def _write_repo_streaming(
    root_path: Path,
    files: list[Path],
    *,
    repo_key: str,
    tenant_id: str,
    client: Any,
    progress_callback: ProgressCallback | None = None,
) -> dict[str, int]:
    """Parse and write huge repos in bounded-memory file shards."""
    total_files = len(files)
    total_nodes = 0
    total_edges = 0
    for start in range(0, total_files, _STREAMING_SHARD_SIZE):
        shard_files = files[start : start + _STREAMING_SHARD_SIZE]
        done = min(start + len(shard_files), total_files)
        if progress_callback is not None:
            progress_callback(
                "parsing", f"Streaming monorepo ({done}/{total_files} files)…"
            )
        shard_graph = _parse_shard(root_path, shard_files, repo_key)
        counts = write_code_graph(client, shard_graph, tenant_id=tenant_id)
        total_nodes += counts["nodes_written"]
        total_edges += counts["edges_written"]
    return {"nodes_written": total_nodes, "edges_written": total_edges}


def write_repo_code_graph_with_key(
    root: str | Path,
    *,
    repo_key: str,
    repo_root: str | None = None,
    source_commit: str | None = None,
    kind: str = "repo",
    tenant_id: str = "default",
    client: Any = None,
    progress_callback: ProgressCallback | None = None,
) -> dict[str, int]:
    """Parse ``root`` and persist its code graph under an explicit ``repo_key``.

    Used by remote connectors (such as the GitHub App ephemeral tarball
    ingestor) where the canonical identity is ``owner/repo`` rather than
    a persistent local checkout path.
    """
    if client is None:
        from backend.storage.neo4j_client import Neo4jStorageClient

        client = Neo4jStorageClient.from_config(_load_config())
    root_path = Path(os.path.realpath(root))
    files = collect_parseable_files(root_path)
    if len(files) >= _STREAMING_FILE_THRESHOLD:
        counts = _write_repo_streaming(
            root_path,
            files,
            repo_key=repo_key,
            tenant_id=tenant_id,
            client=client,
            progress_callback=progress_callback,
        )
    else:
        graph = parse_repo(
            root_path, repo_key=repo_key, progress_callback=progress_callback
        )
        counts = write_code_graph(
            client, graph, tenant_id=tenant_id, progress_callback=progress_callback
        )
    write_index_meta(
        client,
        tenant_id,
        repo_key=repo_key,
        repo_root=repo_root or repo_key,
        source_commit=source_commit,
        kind=kind,
    )
    return counts


def write_repo_code_graph(
    root: str | Path, tenant_id: str = "default", client: Any = None
) -> dict[str, int]:
    """Parse ``root`` and persist its code graph for ``tenant_id``.

    Also stamps the index metadata with the repo's current git HEAD
    (``None`` when ``root`` is not a git checkout — never fabricated).
    The graph and the stamp share one repo key, derived from the
    checkout (see :func:`derive_repo_key`).
    """
    root_path = Path(os.path.realpath(root))
    return write_repo_code_graph_with_key(
        root_path,
        repo_key=derive_repo_key(root_path),
        repo_root=str(root_path),
        source_commit=git_head_sha(root_path),
        kind="repo",
        tenant_id=tenant_id,
        client=client,
    )


# ---------------------------------------------------------------------------
# Git probes (stdlib subprocess; every failure reads as "unknown")
# ---------------------------------------------------------------------------


def _run_git(root: str | Path, args: list[str]) -> str | None:
    """Run ``git -C <root> <args>``; return stdout, or None on any failure."""
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout


def git_head_sha(root: str | Path) -> str | None:
    """The HEAD commit SHA of the checkout at ``root``, or None.

    None when ``root`` is not inside a git work tree, git is missing,
    or the repo has no commits yet — callers must treat the commit as
    unknown rather than guess.
    """
    out = _run_git(root, ["rev-parse", "HEAD"])
    if out is None:
        return None
    sha = out.strip()
    return sha or None


def git_origin_repo(root: str | Path) -> str | None:
    """The ``owner/repo`` slug of the checkout's origin remote, or None."""
    out = _run_git(root, ["remote", "get-url", "origin"])
    if out is None:
        return None
    url = out.strip().rstrip("/").removesuffix(".git")
    parts = [p for p in re.split(r"[/:]", url) if p]
    if len(parts) < 2:
        return None
    return f"{parts[-2]}/{parts[-1]}"


def derive_repo_key(root: str | Path) -> str:
    """Stable identity of the repo at ``root`` within a tenant's graph.

    The git origin slug (``owner/repo``) when the checkout has an
    origin remote — two checkouts of the same repo ARE the same repo
    and share a key. Otherwise the checkout's absolute real path,
    the same identifier the index stamp records as ``repo_root``:
    stable for a given checkout on a given machine. Upload and SCIP
    graphs have no checkout to derive from; their keys come from the
    payload instead (see :func:`write_parsed_code_graph` and
    ``scip_ingest.write_scip_graph``).
    """
    slug = git_origin_repo(root)
    if slug:
        return slug
    return str(Path(os.path.realpath(root)))


def git_pull_ff_only(root: str | Path, after_sha: str | None) -> dict[str, Any]:
    """Attempt a safe fast-forward of the checkout at ``root``.

    Used by the GitHub push webhook to sync a local checkout to the
    pushed commit before updating its graph. Returns a disclosure
    dict ``{"pulled": bool, "head": str | None, "reason": str | None}``
    where ``head`` is the checkout's HEAD after the attempt (its
    previous HEAD when the pull was skipped).

    Safety contract — the pull happens only when ALL of these hold:
    the push names a target commit different from HEAD, the working
    tree is completely clean (``git status --porcelain`` empty,
    untracked files included), the target is fetchable from origin,
    and the move is a fast-forward (``git merge --ff-only``). Any
    failure skips the pull and leaves the checkout exactly as it
    was: nothing is ever reset, and local changes are never
    discarded.
    """
    head = git_head_sha(root)
    if head is None:
        return {"pulled": False, "head": None, "reason": "not a git checkout"}
    if not after_sha or set(after_sha) == {"0"}:
        # No target (or a branch-deletion push, whose after is all
        # zeroes): nothing to move to.
        return {"pulled": False, "head": head, "reason": "push carries no target commit"}
    if after_sha == head:
        return {"pulled": False, "head": head, "reason": "already at the pushed commit"}
    status = _run_git(root, ["status", "--porcelain"])
    if status is None:
        return {"pulled": False, "head": head, "reason": "git status failed"}
    if status.strip():
        return {"pulled": False, "head": head, "reason": "working tree is dirty"}
    if _run_git(root, ["fetch", "origin"]) is None:
        return {"pulled": False, "head": head, "reason": "git fetch failed"}
    if _run_git(root, ["cat-file", "-e", f"{after_sha}^{{commit}}"]) is None:
        return {
            "pulled": False,
            "head": head,
            "reason": "pushed commit is not fetchable from origin",
        }
    if _run_git(root, ["merge", "--ff-only", after_sha]) is None:
        return {"pulled": False, "head": head, "reason": "not a fast-forward"}
    return {"pulled": True, "head": after_sha, "reason": None}


def _parse_name_status_z(out: str) -> set[str]:
    """Paths from ``git diff --name-status -z`` output (renames give both)."""
    paths: set[str] = set()
    fields = out.split("\0")
    i = 0
    while i < len(fields):
        status = fields[i]
        i += 1
        if not status:
            continue
        if status[0] in ("R", "C"):
            # Rename/copy: old path then new path follow as fields.
            if i + 1 < len(fields):
                paths.add(fields[i])
                paths.add(fields[i + 1])
            i += 2
        elif i < len(fields):
            paths.add(fields[i])
            i += 1
    return paths


def _parse_porcelain_z(out: str) -> set[str]:
    """Paths from ``git status --porcelain -z`` output (renames give both)."""
    paths: set[str] = set()
    fields = out.split("\0")
    i = 0
    while i < len(fields):
        entry = fields[i]
        i += 1
        if len(entry) < 4:
            continue
        status = entry[:2]
        paths.add(entry[3:])
        # In -z mode a rename/copy source path follows as its own field.
        if ("R" in status or "C" in status) and i < len(fields):
            paths.add(fields[i])
            i += 1
    return paths


def git_changed_paths(root: str | Path, since_sha: str) -> set[str] | None:
    """Repo-relative paths changed between ``since_sha`` and the work tree.

    Union of the committed diff ``since_sha..HEAD`` (renames contribute
    both paths) and every path ``git status`` reports — staged,
    unstaged, deleted and untracked — all relative to ``root`` (which
    may be a subdirectory of the checkout). Returns None when the
    change set cannot be determined (not a git repo, ``since_sha``
    unknown to this repo's history, git failure): callers must fall
    back to a full re-parse rather than trust a partial answer.
    """
    if not since_sha:
        return None
    if _run_git(root, ["cat-file", "-e", f"{since_sha}^{{commit}}"]) is None:
        return None
    diff = _run_git(
        root, ["diff", "--name-status", "-M", "-z", "--relative", f"{since_sha}..HEAD"]
    )
    if diff is None:
        return None
    status = _run_git(
        root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
    )
    if status is None:
        return None
    return _parse_name_status_z(diff) | _parse_porcelain_z(status)


# ---------------------------------------------------------------------------
# Index metadata: provenance stamp for a tenant's indexed repo
# ---------------------------------------------------------------------------

INDEX_META_LABEL = "CodeIndexMeta"


def write_index_meta(
    client: Any,
    tenant_id: str,
    *,
    repo_key: str,
    repo_root: str,
    source_commit: str | None,
    kind: str,
) -> dict[str, Any]:
    """Upsert the tenant's index-provenance stamp for one repo.

    The stamp is a ``CodeIndexMeta`` node in the same graph (keyed by
    the structural ``code_key`` like every code node), chosen over a
    side store because it inherits the writer's tenant scoping and
    parameterized-Cypher discipline and is readable through the same
    client as the graph itself. One stamp per (tenant, repo_key);
    re-ingesting overwrites it. An unknown ``source_commit`` is
    stored as null (which clears any previous SHA) — never a guess.

    The MERGE is issued directly rather than via
    ``upsert_structural_node`` so the metadata write stays visibly
    distinct from code-node writes: the stamp is not a code node and
    carries no ``qualified_name``.
    """
    from backend.ingestion.graph_write import structural_key

    indexed_at = datetime.now(UTC).isoformat()
    properties: dict[str, Any] = {
        "tenant_id": tenant_id,
        "repo_key": repo_key,
        "repo_root": repo_root,
        "indexed_at": indexed_at,
        "kind": kind,
        # Always present in the map: with SET +=, a null value clears
        # a previously stamped SHA instead of leaving it behind when
        # the new provenance is unknown.
        "source_commit": source_commit,
    }
    client.execute_write(
        f"""
        MERGE (m:{INDEX_META_LABEL} {{code_key: $code_key}})
        SET m += $properties
        """,
        {
            "code_key": structural_key(tenant_id, INDEX_META_LABEL, repo_key),
            "properties": properties,
        },
    )
    return {
        "repo_key": repo_key,
        "repo_root": repo_root,
        "source_commit": source_commit,
        "indexed_at": indexed_at,
        "kind": kind,
    }


def read_index_meta(
    client: Any, tenant_id: str, repo_key: str | None = None
) -> dict[str, Any] | None:
    """The tenant's most recent index stamp (or one repo's), or None.

    None means nothing was ever stamped for the tenant (graphs
    ingested before index metadata existed) — consumers disclose
    provenance as unknown rather than inventing it.
    """
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
    rows = client.execute_read(query, {"tenant_id": tenant_id, "repo_key": repo_key})
    return rows[0] if rows else None


def find_index_meta_for_root(client: Any, repo_root: str) -> list[dict[str, Any]]:
    """All tenants' index stamps for one on-disk repo root.

    Used by the GitHub push webhook to resolve which tenant(s) indexed
    a local checkout: the stamp is the only durable tenant ↔ repo-root
    association the code graph keeps.
    """
    query = """
    MATCH (m:CodeIndexMeta)
    WHERE m.repo_root = $repo_root
    RETURN m.tenant_id AS tenant_id, m.repo_key AS repo_key,
           m.repo_root AS repo_root, m.source_commit AS source_commit,
           m.indexed_at AS indexed_at, m.kind AS kind
    ORDER BY m.indexed_at DESC
    """
    return client.execute_read(query, {"repo_root": repo_root})


# ---------------------------------------------------------------------------
# Incremental update: re-parse changed files, keep the rest of the graph
# ---------------------------------------------------------------------------


def load_stored_code_graph(
    client: Any, tenant_id: str, repo_key: str | None = None
) -> CodeGraph:
    """Read the tenant's stored code graph back into parse-space form.

    Placeholder nodes (``resolved = false``) are excluded: in
    parse-space they are not nodes at all, only edge targets, and the
    writer recreates them deterministically from the edge set. Edge
    target labels come from the stored target node (parsed or
    placeholder), which is exactly the label a full parse's build()
    correction would have produced. With ``repo_key`` given, only
    that repo's nodes and edges are loaded (nodes ingested before
    repo namespacing, whose ``repo_key`` is absent, match only the
    empty key — they belong to no repo until re-indexed).
    """
    node_rows = client.execute_read(
        """
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
          AND coalesce(n.resolved, true) = true
          AND ($repo_key IS NULL OR coalesce(n.repo_key, '') = $repo_key)
        RETURN labels(n)[0] AS label, n.name AS name,
               n.qualified_name AS qualified_name, n.path AS path,
               n.line AS line, n.end_line AS end_line,
               n.language AS language, coalesce(n.repo_key, '') AS repo_key
        """,
        {"tenant_id": tenant_id, "repo_key": repo_key},
    )
    nodes = [
        CodeNode(
            label=str(row["label"]),
            name=str(row.get("name") or ""),
            qualified_name=str(row["qualified_name"]),
            path=str(row.get("path") or ""),
            line=int(row.get("line") or 0),
            language=str(row.get("language") or ""),
            resolved=True,
            end_line=(
                int(row["end_line"])
                if isinstance(row.get("end_line"), int) and row["end_line"] > 0
                else None
            ),
            repo_key=str(row.get("repo_key") or ""),
        )
        for row in node_rows
    ]
    parsed_keys = {(node.repo_key, node.qualified_name) for node in nodes}
    edge_rows = client.execute_read(
        """
        MATCH (a)-[r]->(b)
        WHERE a.tenant_id = $tenant_id
          AND b.tenant_id = $tenant_id
          AND type(r) IN $edge_types
          AND ($repo_key IS NULL OR (coalesce(a.repo_key, '') = $repo_key
               AND coalesce(b.repo_key, '') = $repo_key))
        RETURN type(r) AS type, a.qualified_name AS source_qn,
               labels(a)[0] AS source_label, b.qualified_name AS target_qn,
               labels(b)[0] AS target_label, coalesce(a.repo_key, '') AS repo_key
        """,
        {"tenant_id": tenant_id, "edge_types": list(EDGE_TYPES), "repo_key": repo_key},
    )
    edges = [
        CodeEdge(
            type=str(row["type"]),
            source_qn=str(row["source_qn"]),
            source_label=str(row["source_label"]),
            target_qn=str(row["target_qn"]),
            target_label=str(row["target_label"]),
            repo_key=str(row.get("repo_key") or ""),
        )
        for row in edge_rows
        if (str(row.get("repo_key") or ""), str(row.get("source_qn") or ""))
        in parsed_keys
    ]
    return CodeGraph(nodes=nodes, edges=edges)


def plan_incremental_update(
    stored: CodeGraph, changed_paths: set[str]
) -> set[str]:
    """File paths that must be re-parsed for an incremental update.

    The changed files themselves, plus every file that owns an edge
    INTO a changed file's nodes: deleting a changed file's nodes
    deletes those incoming edges with them, and only re-parsing the
    owner recomputes them against the new definitions (a renamed
    callee must not leave its callers' CALLS edges dangling or
    pointing at the old name). One hop suffices because an edge's
    existence and target are determined solely by its source file's
    own content plus the target's node label — both stable for files
    outside this set.
    """
    reparse = set(changed_paths)
    changed_qns = {
        node.qualified_name for node in stored.nodes if node.path in changed_paths
    }
    if not changed_qns:
        return reparse
    path_by_qn = {node.qualified_name: node.path for node in stored.nodes}
    for edge in stored.edges:
        if edge.target_qn in changed_qns:
            source_path = path_by_qn.get(edge.source_qn)
            if source_path:
                reparse.add(source_path)
    return reparse


def update_code_graph_incremental(
    stored: CodeGraph,
    root: str | Path,
    changed_paths: set[str],
    *,
    repo_key: str | None = None,
) -> tuple[CodeGraph, set[str]]:
    """Apply an incremental update to ``stored`` purely, in memory.

    Returns ``(updated_graph, reparse_paths)``. Nodes owned by
    re-parsed files are dropped together with every edge they source;
    the files are re-parsed from disk with target-label correction
    seeded from the surviving nodes, so the result equals a full
    :func:`parse_repo` of the current tree (asserted by the
    equivalence test in ``backend/tests/test_code_freshness.py``).
    """
    reparse_paths = plan_incremental_update(stored, changed_paths)
    survivors = [node for node in stored.nodes if node.path not in reparse_paths]
    survivor_qns = {node.qualified_name for node in survivors}
    kept_edges = [edge for edge in stored.edges if edge.source_qn in survivor_qns]
    known_labels = {node.qualified_name: node.label for node in survivors}
    effective_key = repo_key if repo_key is not None else derive_repo_key(root)
    fresh = parse_files(
        root,
        sorted(reparse_paths),
        known_target_labels=known_labels,
        repo_key=effective_key,
    )
    merged: dict[tuple[str, str, str], CodeEdge] = {}
    for edge in kept_edges + fresh.edges:
        merged[(edge.type, edge.source_qn, edge.target_qn)] = edge
    return (
        CodeGraph(nodes=survivors + fresh.nodes, edges=list(merged.values())),
        reparse_paths,
    )


def _delete_nodes_for_paths(
    client: Any, tenant_id: str, paths: list[str], repo_key: str = ""
) -> None:
    """DETACH DELETE every code node owned by one of ``paths``.

    Scoped to ``repo_key`` as well as tenant and path: another repo
    in the same tenant may own nodes at the very same relative
    paths, and an update of one repo must never delete the other's.
    """
    if not paths:
        return
    client.execute_write(
        """
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND n.path IN $paths
          AND coalesce(n.repo_key, '') = $repo_key
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
        DETACH DELETE n
        """,
        {"tenant_id": tenant_id, "paths": paths, "repo_key": repo_key},
    )


def _delete_orphan_placeholders(
    client: Any, tenant_id: str, repo_key: str = ""
) -> None:
    """Delete one repo's placeholder nodes no remaining edge references.

    A full write only ever creates a placeholder because some edge
    targets it; after an incremental delete/rewrite, a placeholder
    whose last referencing edge disappeared must go too, or the
    stored graph would keep nodes a full re-parse never produces.
    Scoped to ``repo_key`` so one repo's cleanup never touches
    another repo's placeholders.
    """
    client.execute_write(
        """
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function)
          AND coalesce(n.resolved, true) = false
          AND coalesce(n.repo_key, '') = $repo_key
          AND NOT (n)--()
        DELETE n
        """,
        {"tenant_id": tenant_id, "repo_key": repo_key},
    )


def apply_incremental_files(
    root: str | Path,
    *,
    tenant_id: str,
    repo_key: str,
    changed_paths: set[str],
    head_sha: str | None,
    repo_root: str | None = None,
    kind: str = "repo",
    client: Any = None,
) -> dict[str, Any]:
    """Incrementally update Neo4j for an explicit set of ``changed_paths``.

    Shared by local ``git diff`` updates and remote GitHub Compare API
    updates so Neo4j node deletion, re-parsing, placeholder cleanup, and
    index stamping stay in one place.
    """
    if client is None:
        from backend.storage.neo4j_client import Neo4jStorageClient

        client = Neo4jStorageClient.from_config(_load_config())
    root_path = Path(os.path.realpath(root))
    if not changed_paths:
        return {
            "nodes_written": 0,
            "edges_written": 0,
            "changed_files": 0,
            "reparsed_files": 0,
            "mode": "incremental",
            "source_commit": head_sha,
            "repo_key": repo_key,
        }
    stored = load_stored_code_graph(client, tenant_id, repo_key=repo_key)
    updated, reparse_paths = update_code_graph_incremental(
        stored, root_path, changed_paths, repo_key=repo_key
    )
    _delete_nodes_for_paths(
        client, tenant_id, sorted(reparse_paths), repo_key=repo_key
    )
    path_by_qn = {node.qualified_name: node.path for node in updated.nodes}
    sub_nodes = [node for node in updated.nodes if node.path in reparse_paths]
    sub_edges = [
        edge for edge in updated.edges if path_by_qn.get(edge.source_qn) in reparse_paths
    ]
    known_keys = {node.key for node in updated.nodes}
    for node in sub_nodes:
        _write_node(client, node, tenant_id)
    for edge in sub_edges:
        _write_placeholder_node(client, edge, tenant_id, known_keys)
    for edge in sub_edges:
        _write_edge(client, edge, tenant_id)
    _delete_orphan_placeholders(client, tenant_id, repo_key=repo_key)
    stamp = write_index_meta(
        client,
        tenant_id,
        repo_key=repo_key,
        repo_root=repo_root or str(root_path),
        source_commit=head_sha,
        kind=kind,
    )
    return {
        "nodes_written": len(sub_nodes),
        "edges_written": len(sub_edges),
        "changed_files": len(changed_paths),
        "reparsed_files": len(reparse_paths),
        "mode": "incremental",
        "source_commit": head_sha,
        "indexed_at": stamp["indexed_at"],
        "repo_key": repo_key,
    }


def delete_repo_code_graph(client: Any, tenant_id: str, repo_key: str) -> None:
    """Purge all code-graph nodes and index metadata for ``(tenant_id, repo_key)``."""
    client.execute_write(
        """
        MATCH (n)
        WHERE n.tenant_id = $tenant_id
          AND coalesce(n.repo_key, '') = $repo_key
          AND (n:CodeFile OR n:CodeModule OR n:Class OR n:Function OR n:CodeIndexMeta)
        DETACH DELETE n
        """,
        {"tenant_id": tenant_id, "repo_key": repo_key},
    )


def update_repo_code_graph(
    root: str | Path, tenant_id: str = "default", client: Any = None
) -> dict[str, Any]:
    """Incrementally refresh the stored code graph for ``root``.

    Diffs the stored index stamp's commit against the checkout's
    current state (see :func:`git_changed_paths`), re-parses only the
    changed files and their incoming-edge owners, syncs Neo4j to the
    result, and re-stamps the index at the new HEAD. Falls back to a
    full re-parse — with a log line saying so — whenever the
    incremental inputs are unavailable: no stamp, a non-git repo, an
    unknown stamped SHA, or an undeterminable change set.

    Everything — the stamp lookup, the stored-graph load, the
    deletes and the re-stamp — is scoped to this repo's key, so
    updating one repo never reads, deletes or re-stamps another
    repo sharing the tenant.
    """
    if client is None:
        from backend.storage.neo4j_client import Neo4jStorageClient

        client = Neo4jStorageClient.from_config(_load_config())
    root_path = Path(os.path.realpath(root))
    repo_key = derive_repo_key(root_path)
    meta = read_index_meta(client, tenant_id, repo_key=repo_key)
    indexed_sha = (meta or {}).get("source_commit")
    head_sha = git_head_sha(root_path)
    changed = git_changed_paths(root_path, indexed_sha) if indexed_sha else None
    if changed is None or head_sha is None:
        logger.info(
            "Incremental update unavailable for %s (indexed_sha=%s, head=%s); "
            "falling back to a full re-parse",
            root_path,
            indexed_sha,
            head_sha,
        )
        counts = write_repo_code_graph(root_path, tenant_id=tenant_id, client=client)
        return {**counts, "mode": "full", "changed_files": None, "repo_key": repo_key}
    return apply_incremental_files(
        root_path,
        tenant_id=tenant_id,
        repo_key=repo_key,
        changed_paths=changed,
        head_sha=head_sha,
        repo_root=str(root_path),
        kind="repo",
        client=client,
    )


def _load_config() -> Any:
    from backend.config import get_config

    return get_config()


__all__ = [
    "EDGE_TYPES",
    "INDEX_META_LABEL",
    "MAX_FILE_BYTES",
    "NODE_LABELS",
    "CodeEdge",
    "CodeGraph",
    "CodeNode",
    "apply_incremental_files",
    "delete_repo_code_graph",
    "derive_repo_key",
    "find_index_meta_for_root",
    "git_changed_paths",
    "git_head_sha",
    "git_origin_repo",
    "git_pull_ff_only",
    "graph_from_payload",
    "load_stored_code_graph",
    "parse_files",
    "parse_repo",
    "plan_incremental_update",
    "read_index_meta",
    "update_code_graph_incremental",
    "update_repo_code_graph",
    "write_code_graph",
    "write_index_meta",
    "write_parsed_code_graph",
    "write_repo_code_graph",
]
