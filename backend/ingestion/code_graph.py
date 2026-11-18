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
  ``tenant_id`` and ``language``.
* Edges: ``IMPORTS`` (module -> imported module), ``CALLS``
  (function/module -> resolved callee), ``DEFINES`` (file -> its module,
  module -> top-level class/function, class -> its methods) and
  ``INHERITS`` (class -> resolved base class).

Qdrant note (per ``docs/evidence-first-plan.md``): code nodes are
structural AST-derived nodes, NOT text chunks, so they carry NO Qdrant
point ID and the chunk dual-write rule does not apply to them. Where a
code file also has ingested chunks, the two are linked only by the
shared ``path`` property — no point IDs are invented here.

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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

MAX_FILE_BYTES = 200_000

_SKIPPED_DIRS = {"node_modules", "vendor", ".git", "dist", "build", "__pycache__"}
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
}

NODE_LABELS = ("CodeFile", "CodeModule", "Class", "Function")
EDGE_TYPES = ("IMPORTS", "CALLS", "DEFINES", "INHERITS")


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

    @property
    def key(self) -> tuple[str, str]:
        return (self.label, self.qualified_name)

    def properties(self, tenant_id: str) -> dict[str, Any]:
        return {
            "name": self.name,
            "qualified_name": self.qualified_name,
            "path": self.path,
            "line": self.line,
            "tenant_id": tenant_id,
            "language": self.language,
            "resolved": self.resolved,
        }


@dataclass
class CodeEdge:
    """One directed edge between two nodes, by qualified name.

    ``target_label`` names the label of the target node so the writer
    can create a placeholder node for a resolved target that was not
    itself parsed (e.g. an imported external module).
    """

    type: str
    source_qn: str
    source_label: str
    target_qn: str
    target_label: str


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

    def __init__(self) -> None:
        self.nodes: dict[tuple[str, str], CodeNode] = {}
        self.edges: dict[tuple[str, str, str], CodeEdge] = {}

    def add_node(self, node: CodeNode) -> CodeNode:
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
            )

    def build(self) -> CodeGraph:
        # A qualified name identifies one symbol regardless of label;
        # when the target was parsed, correct the edge's target label
        # to the parsed node's label (e.g. a call to an imported class).
        label_by_qn = {
            node.qualified_name: node.label for node in self.nodes.values()
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


def parse_repo(root: str | Path) -> CodeGraph:
    """Parse the repo tree at ``root`` into an in-memory :class:`CodeGraph`.

    Pure: no database or network access. Paths on nodes are relative to
    ``root`` (POSIX separators) so results are machine-independent.
    """
    root_path = Path(os.path.realpath(root))
    builder = _GraphBuilder()
    if not root_path.is_dir():
        return builder.build()
    for path in sorted(root_path.rglob("*")):
        if not path.is_file() or not _is_parseable_file(path, root_path):
            continue
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
        else:
            _parse_declared_file(
                builder, file_node, module_node, path, relative_path, language
            )
    return builder.build()


# ---------------------------------------------------------------------------
# Neo4j writer (graph_write.py patterns: tenant-scoped, parameterized)
# ---------------------------------------------------------------------------


def _write_node(client: Any, node: CodeNode, tenant_id: str) -> None:
    from backend.ingestion.graph_write import structural_key, upsert_structural_node

    upsert_structural_node(
        client,
        label=node.label,
        allowed_labels=NODE_LABELS,
        key_field="code_key",
        key_value=structural_key(tenant_id, node.label, node.qualified_name),
        properties=node.properties(tenant_id),
    )


def _write_placeholder_node(
    client: Any, edge: CodeEdge, tenant_id: str, parsed_keys: set[tuple[str, str]]
) -> None:
    """Create a bare node for a resolved target outside the parsed tree."""
    if (edge.target_label, edge.target_qn) in parsed_keys:
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
    )
    _write_node(client, placeholder, tenant_id)


def _write_edge(client: Any, edge: CodeEdge, tenant_id: str) -> None:
    from backend.ingestion.graph_write import structural_key, upsert_structural_edge

    upsert_structural_edge(
        client,
        edge_type=edge.type,
        allowed_edge_types=EDGE_TYPES,
        key_field="code_key",
        from_key=structural_key(tenant_id, edge.source_label, edge.source_qn),
        to_key=structural_key(tenant_id, edge.target_label, edge.target_qn),
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
    nodes: list[dict[str, Any]], edges: list[dict[str, Any]]
) -> CodeGraph:
    """Build a :class:`CodeGraph` from a pre-parsed payload.

    Used by ``POST /api/v1/code/ingest-graph``: a client (the CLI's
    ``xray index --local``) parses a repo it can read and uploads the
    graph, so the server needs no filesystem access to that repo.
    Labels / edge types are validated against this module's whitelists;
    anything else is dropped (fail closed). ``resolved`` defaults to
    True and is only False for client-marked external placeholders.
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
            )
        )
    return CodeGraph(nodes=parsed_nodes, edges=parsed_edges)


def write_parsed_code_graph(
    client: Any,
    nodes: list[dict[str, Any]],
    edges: list[dict[str, Any]],
    tenant_id: str = "default",
) -> dict[str, int]:
    """Persist a pre-parsed graph payload (see :func:`graph_from_payload`)."""
    graph = graph_from_payload(nodes, edges)
    return write_code_graph(client, graph, tenant_id=tenant_id)


def write_repo_code_graph(
    root: str | Path, tenant_id: str = "default", client: Any = None
) -> dict[str, int]:
    """Parse ``root`` and persist its code graph for ``tenant_id``."""
    if client is None:
        from backend.storage.neo4j_client import Neo4jStorageClient

        client = Neo4jStorageClient.from_config(_load_config())
    graph = parse_repo(root)
    return write_code_graph(client, graph, tenant_id=tenant_id)


def _load_config() -> Any:
    from backend.config import get_config

    return get_config()


__all__ = [
    "EDGE_TYPES",
    "MAX_FILE_BYTES",
    "NODE_LABELS",
    "CodeEdge",
    "CodeGraph",
    "CodeNode",
    "graph_from_payload",
    "parse_repo",
    "write_code_graph",
    "write_parsed_code_graph",
    "write_repo_code_graph",
]
