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
  imported module. Dynamic calls, calls on arbitrary objects and
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
import logging
import os
import re
import subprocess
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

    def build(self) -> CodeGraph:
        # A qualified name identifies one symbol regardless of label;
        # when the target was parsed, correct the edge's target label
        # to the parsed node's label (e.g. a call to an imported class).
        # Nodes parsed in this pass win over the externally-known
        # labels (which describe files this pass did not re-parse).
        label_by_qn = {
            **self.known_target_labels,
            **{node.qualified_name: node.label for node in self.nodes.values()},
        }
        edges = []
        for edge in self.edges.values():
            parsed_label = label_by_qn.get(edge.target_qn)
            if parsed_label is not None and parsed_label != edge.target_label:
                edge = CodeEdge(
                    type=edge.type,
                    source_qn=edge.source_qn,
                    source_label=edge.source_label,
                    target_qn=edge.target_qn,
                    target_label=parsed_label,
                    repo_key=edge.repo_key,
                )
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
        self.module_defs: dict[str, tuple[str, str]] = {}
        self.class_methods: dict[str, set[str]] = {}

    # -- resolution helpers -------------------------------------------------

    def _resolve_name(self, name: str) -> tuple[str, str] | None:
        """Resolve a simple name to (qualified name, node label)."""
        if name in self.module_defs:
            suffix, label = self.module_defs[name]
            return f"{self.module_qn}.{suffix}", label
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
        for node in tree.body:
            self._visit_top_level(node)

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
            self.imported_symbols[alias.asname or alias.name] = (
                f"{target_module}.{alias.name}"
            )

    def _import_from_target(self, node: ast.ImportFrom) -> str:
        if node.level:
            package_parts = self.module_qn.split(".")
            # For a package __init__ the module qn IS the package; for a
            # plain module the package is its parent.
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
    "method",
}
_TS_IMPORT_TYPES = {
    "import_statement",
    "import_declaration",
    "import_spec",
    "import_or_export",
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
        if child.type in (
            "superclass",
            "class_heritage",
            "extends_clause",
            "extends_type_clause",
            "super_interfaces",
        ):
            for sub in child.children:
                if sub.type in ("type_identifier", "identifier"):
                    val = _ts_node_text(sub, source).strip()
                    if val:
                        bases.append(val)
                elif sub.type in ("extends_clause", "type_identifier"):
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

    def walk(node: Any, container: CodeNode) -> None:
        ntype = node.type
        if ntype in _TS_IMPORT_TYPES:
            for target in _ts_extract_import_targets(node, source):
                builder.add_edge("IMPORTS", module_node, target, "CodeModule")
                alias = target.rsplit("/", 1)[-1].rsplit(".", 1)[-1]
                if alias:
                    imported_aliases[alias] = target
            return

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
                for base in _ts_extract_superclasses(node, source):
                    builder.add_edge("INHERITS", class_node, base, "Class")
                for child in node.children:
                    walk(child, class_node)
                return

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
                for child in node.children:
                    walk(child, func_node)
                return

        if ntype in _TS_CALL_TYPES and container.label == "Function":
            pending_calls.append((container, node))

        for child in node.children:
            walk(child, container)

    walk(tree.root_node, module_node)
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


def parse_repo(root: str | Path, repo_key: str | None = None) -> CodeGraph:
    """Parse the repo tree at ``root`` into an in-memory :class:`CodeGraph`.

    Pure: no database or network access. Paths on nodes are relative to
    ``root`` (POSIX separators) so results are machine-independent.
    Every node/edge is stamped with ``repo_key`` — derived from
    ``root`` via :func:`derive_repo_key` when not given (that probe
    reads the checkout's local git config only).
    """
    root_path = Path(os.path.realpath(root))
    builder = _GraphBuilder(
        repo_key=derive_repo_key(root_path) if repo_key is None else repo_key
    )
    if not root_path.is_dir():
        return builder.build()
    for path in sorted(root_path.rglob("*")):
        if not path.is_file() or not _is_parseable_file(path, root_path):
            continue
        _parse_one_file(builder, root_path, path)
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


def write_code_graph(
    client: Any, graph: CodeGraph, tenant_id: str = "default"
) -> dict[str, int]:
    """Persist a parsed :class:`CodeGraph` to Neo4j via ``client``.

    ``client`` is the existing Neo4j storage client (anything exposing
    ``execute_write(query, parameters)``, e.g. ``Neo4jStorageClient``).
    Every query is parameterized; labels/relationship types are
    interpolated only from this module's whitelists. Code nodes carry
    no Qdrant point ID (see module docstring). Returns write counts.
    """
    parsed_keys = {node.key for node in graph.nodes}
    for node in graph.nodes:
        _write_node(client, node, tenant_id)
    for edge in graph.edges:
        _write_placeholder_node(client, edge, tenant_id, parsed_keys)
    for edge in graph.edges:
        _write_edge(client, edge, tenant_id)
    return {"nodes_written": len(graph.nodes), "edges_written": len(graph.edges)}


MAX_INGEST_NODES = 20000
MAX_INGEST_EDGES = 50000


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


def write_repo_code_graph(
    root: str | Path, tenant_id: str = "default", client: Any = None
) -> dict[str, int]:
    """Parse ``root`` and persist its code graph for ``tenant_id``.

    Also stamps the index metadata with the repo's current git HEAD
    (``None`` when ``root`` is not a git checkout — never fabricated).
    The graph and the stamp share one repo key, derived from the
    checkout (see :func:`derive_repo_key`).
    """
    if client is None:
        from backend.storage.neo4j_client import Neo4jStorageClient

        client = Neo4jStorageClient.from_config(_load_config())
    root_path = Path(os.path.realpath(root))
    repo_key = derive_repo_key(root_path)
    graph = parse_repo(root_path, repo_key=repo_key)
    counts = write_code_graph(client, graph, tenant_id=tenant_id)
    write_index_meta(
        client,
        tenant_id,
        repo_key=repo_key,
        repo_root=str(root_path),
        source_commit=git_head_sha(root_path),
        kind="repo",
    )
    return counts


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
    stored: CodeGraph, root: str | Path, changed_paths: set[str]
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
    fresh = parse_files(
        root,
        sorted(reparse_paths),
        known_target_labels=known_labels,
        repo_key=derive_repo_key(root),
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
    if not changed:
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
        stored, root_path, changed
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
        repo_root=str(root_path),
        source_commit=head_sha,
        kind="repo",
    )
    return {
        "nodes_written": len(sub_nodes),
        "edges_written": len(sub_edges),
        "changed_files": len(changed),
        "reparsed_files": len(reparse_paths),
        "mode": "incremental",
        "source_commit": head_sha,
        "indexed_at": stamp["indexed_at"],
        "repo_key": repo_key,
    }


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
