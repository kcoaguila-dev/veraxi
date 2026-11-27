"""Baseline accuracy fixture for Dart/Flutter code-graph call resolution.

Phase 16 / Phase 5 (ADR-0007) groundwork: a deterministic set of
Dart/Flutter call patterns modeled on ``app/`` — relative and
``package:`` imports, ``as`` prefixes, ``export`` barrels, conditional
exports, ``part``/``part of`` generated files, factories, inheritance,
mixins, extensions, function tear-offs, typed fields, multi-hop chains,
same-name collisions, and dynamic/MethodChannel negative controls.

Expected edges use a representation-independent 4-tuple
``(caller_path, caller_symbol, callee_path, callee_symbol)`` so
``parse_repo``, ``parse_scip_payload``, and live LSP results can all be
scored on the same ruler.

Pure and offline: fixture micro-packages (each with ``pubspec.yaml``)
are written to a temporary directory and parsed in memory. No database,
network, or LLM.
"""

from __future__ import annotations

import json
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from backend.ingestion.code_graph import CodeGraph, parse_repo

NormalizedCall = tuple[str, str, str, str]

_PUBSPEC_YAML = (
    "name: fixture\n"
    "description: Veraxi Dart code accuracy fixture\n"
    "publish_to: none\n"
    "environment:\n"
    "  sdk: ^3.5.0\n"
)


@dataclass(frozen=True)
class DartAccuracyCase:
    """One Dart micro-package fixture plus its expected normalized CALLS."""

    id: str
    files: dict[str, str]
    expected_calls: frozenset[NormalizedCall] = field(default_factory=frozenset)


def _case(
    case_id: str,
    files: dict[str, str],
    expected: set[NormalizedCall],
) -> DartAccuracyCase:
    all_files = {"pubspec.yaml": _PUBSPEC_YAML, **files}
    return DartAccuracyCase(
        id=case_id,
        files=all_files,
        expected_calls=frozenset(expected),
    )


CASES: tuple[DartAccuracyCase, ...] = (
    _case(
        "direct-same-file",
        {
            "lib/mod.dart": (
                "void target() {}\n"
                "\n"
                "void caller() {\n"
                "  target();\n"
                "}\n"
            ),
        },
        {("lib/mod.dart", "caller", "lib/mod.dart", "target")},
    ),
    _case(
        "method-same-class",
        {
            "lib/worker.dart": (
                "class Worker {\n"
                "  void run() {\n"
                "    this.build();\n"
                "    helper();\n"
                "  }\n"
                "\n"
                "  void build() {}\n"
                "  void helper() {}\n"
                "}\n"
            ),
        },
        {
            ("lib/worker.dart", "Worker.run", "lib/worker.dart", "Worker.build"),
            ("lib/worker.dart", "Worker.run", "lib/worker.dart", "Worker.helper"),
        },
    ),
    _case(
        "relative-import-call",
        {
            "lib/impl.dart": "void target() {}\n",
            "lib/caller.dart": (
                "import 'impl.dart';\n"
                "\n"
                "void caller() {\n"
                "  target();\n"
                "}\n"
            ),
        },
        {("lib/caller.dart", "caller", "lib/impl.dart", "target")},
    ),
    _case(
        "package-import-call",
        {
            "lib/impl.dart": "void target() {}\n",
            "lib/caller.dart": (
                "import 'package:fixture/impl.dart';\n"
                "\n"
                "void caller() {\n"
                "  target();\n"
                "}\n"
            ),
        },
        {("lib/caller.dart", "caller", "lib/impl.dart", "target")},
    ),
    _case(
        "import-as-prefix",
        {
            "lib/impl.dart": "void target() {}\n",
            "lib/caller.dart": (
                "import 'impl.dart' as impl;\n"
                "\n"
                "void caller() {\n"
                "  impl.target();\n"
                "}\n"
            ),
        },
        {("lib/caller.dart", "caller", "lib/impl.dart", "target")},
    ),
    _case(
        "export-barrel-reexport",
        {
            "lib/src/impl.dart": "void buildItem() {}\n",
            "lib/barrel.dart": "export 'src/impl.dart';\n",
            "lib/caller.dart": (
                "import 'barrel.dart';\n"
                "\n"
                "void caller() {\n"
                "  buildItem();\n"
                "}\n"
            ),
        },
        {("lib/caller.dart", "caller", "lib/src/impl.dart", "buildItem")},
    ),
    _case(
        "conditional-export",
        {
            "lib/popup_types.dart": "class PopupResult {}\n",
            "lib/popup_stub.dart": (
                "import 'popup_types.dart';\n"
                "\n"
                "PopupResult openPopup() => PopupResult();\n"
            ),
            "lib/popup_web.dart": (
                "import 'popup_types.dart';\n"
                "\n"
                "PopupResult openPopup() => PopupResult();\n"
            ),
            "lib/popup.dart": (
                "export 'popup_types.dart';\n"
                "export 'popup_stub.dart'\n"
                "    if (dart.library.js_interop) 'popup_web.dart';\n"
            ),
            "lib/caller.dart": (
                "import 'popup.dart';\n"
                "\n"
                "void caller() {\n"
                "  openPopup();\n"
                "}\n"
            ),
        },
        {("lib/caller.dart", "caller", "lib/popup_stub.dart", "openPopup")},
    ),
    _case(
        "part-and-part-of",
        {
            "lib/db.dart": (
                "part 'db.g.dart';\n"
                "\n"
                "class Database {\n"
                "  void init() {\n"
                "    _migrate();\n"
                "  }\n"
                "}\n"
            ),
            "lib/db.g.dart": (
                "part of 'db.dart';\n"
                "\n"
                "void _migrate() {}\n"
            ),
        },
        {("lib/db.dart", "Database.init", "lib/db.g.dart", "_migrate")},
    ),
    _case(
        "constructor-and-factory",
        {
            "lib/model.dart": (
                "class Item {\n"
                "  Item(this.id);\n"
                "  final String id;\n"
                "\n"
                "  factory Item.fromJson(Map<String, dynamic> json) {\n"
                "    return Item(json['id'] as String);\n"
                "  }\n"
                "}\n"
            ),
            "lib/caller.dart": (
                "import 'model.dart';\n"
                "\n"
                "Item caller(Map<String, dynamic> raw) {\n"
                "  return Item.fromJson(raw);\n"
                "}\n"
            ),
        },
        {
            ("lib/caller.dart", "caller", "lib/model.dart", "Item.fromJson"),
            ("lib/model.dart", "Item.fromJson", "lib/model.dart", "Item"),
        },
    ),
    _case(
        "inherited-method-dispatch",
        {
            "lib/base.dart": (
                "class BaseService {\n"
                "  void logEvent() {}\n"
                "}\n"
            ),
            "lib/sub.dart": (
                "import 'base.dart';\n"
                "\n"
                "class AuthService extends BaseService {\n"
                "  void authenticate() {\n"
                "    logEvent();\n"
                "  }\n"
                "}\n"
            ),
        },
        {
            (
                "lib/sub.dart",
                "AuthService.authenticate",
                "lib/base.dart",
                "BaseService.logEvent",
            ),
        },
    ),
    _case(
        "mixin-method-call",
        {
            "lib/logging_mixin.dart": (
                "mixin LoggingMixin {\n"
                "  void record(String msg) {}\n"
                "}\n"
            ),
            "lib/service.dart": (
                "import 'logging_mixin.dart';\n"
                "\n"
                "class SyncService with LoggingMixin {\n"
                "  void sync() {\n"
                "    record('ok');\n"
                "  }\n"
                "}\n"
            ),
        },
        {
            (
                "lib/service.dart",
                "SyncService.sync",
                "lib/logging_mixin.dart",
                "LoggingMixin.record",
            ),
        },
    ),
    _case(
        "extension-method-call",
        {
            "lib/str_ext.dart": (
                "extension StringTrimExt on String {\n"
                "  String clean() => trim();\n"
                "}\n"
            ),
            "lib/caller.dart": (
                "import 'str_ext.dart';\n"
                "\n"
                "String caller(String input) {\n"
                "  return input.clean();\n"
                "}\n"
            ),
        },
        {("lib/caller.dart", "caller", "lib/str_ext.dart", "StringTrimExt.clean")},
    ),
    _case(
        "function-tearoff-callback",
        {
            "lib/handler.dart": "void submitForm() {}\n",
            "lib/widget.dart": (
                "import 'handler.dart';\n"
                "\n"
                "void bind(void Function() cb) {\n"
                "  cb();\n"
                "}\n"
                "\n"
                "void build() {\n"
                "  bind(submitForm);\n"
                "}\n"
            ),
        },
        {
            ("lib/widget.dart", "build", "lib/widget.dart", "bind"),
            ("lib/widget.dart", "build", "lib/handler.dart", "submitForm"),
        },
    ),
    _case(
        "instance-method-typed-field",
        {
            "lib/repo.dart": (
                "class ChatRepo {\n"
                "  void fetch() {}\n"
                "}\n"
            ),
            "lib/view_model.dart": (
                "import 'repo.dart';\n"
                "\n"
                "class ChatViewModel {\n"
                "  final ChatRepo repo = ChatRepo();\n"
                "\n"
                "  void load() {\n"
                "    repo.fetch();\n"
                "  }\n"
                "}\n"
            ),
        },
        {
            (
                "lib/view_model.dart",
                "ChatViewModel.load",
                "lib/repo.dart",
                "ChatRepo.fetch",
            ),
        },
    ),
    _case(
        "multi-hop-chain",
        {
            "lib/client.dart": (
                "class ApiClient {\n"
                "  void post() {}\n"
                "}\n"
            ),
            "lib/repo.dart": (
                "import 'client.dart';\n"
                "\n"
                "class AuthRepo {\n"
                "  final ApiClient client;\n"
                "  AuthRepo(this.client);\n"
                "\n"
                "  void login() {\n"
                "    client.post();\n"
                "  }\n"
                "}\n"
            ),
            "lib/vm.dart": (
                "import 'repo.dart';\n"
                "\n"
                "class LoginVm {\n"
                "  final AuthRepo repo;\n"
                "  LoginVm(this.repo);\n"
                "\n"
                "  void submit() {\n"
                "    repo.login();\n"
                "  }\n"
                "}\n"
            ),
        },
        {
            ("lib/vm.dart", "LoginVm.submit", "lib/repo.dart", "AuthRepo.login"),
            ("lib/repo.dart", "AuthRepo.login", "lib/client.dart", "ApiClient.post"),
        },
    ),
    _case(
        "same-name-collision-cross-file",
        {
            "lib/alpha.dart": (
                "void shout() {}\n"
                "\n"
                "void callAlpha() {\n"
                "  shout();\n"
                "}\n"
            ),
            "lib/beta.dart": (
                "void shout() {}\n"
                "\n"
                "void callBeta() {\n"
                "  shout();\n"
                "}\n"
            ),
            "lib/caller.dart": (
                "import 'alpha.dart' as alpha;\n"
                "import 'beta.dart' as beta;\n"
                "\n"
                "void caller() {\n"
                "  alpha.shout();\n"
                "  beta.shout();\n"
                "}\n"
            ),
        },
        {
            ("lib/alpha.dart", "callAlpha", "lib/alpha.dart", "shout"),
            ("lib/beta.dart", "callBeta", "lib/beta.dart", "shout"),
            ("lib/caller.dart", "caller", "lib/alpha.dart", "shout"),
            ("lib/caller.dart", "caller", "lib/beta.dart", "shout"),
        },
    ),
    _case(
        "unresolved-dynamic-and-method-channel",
        {
            "lib/handler.dart": "void runTermuxCommand() {}\n",
            "lib/bridge.dart": (
                "void caller(dynamic obj, dynamic channel) {\n"
                "  obj.mystery();\n"
                "  channel.invokeMethod('runTermuxCommand');\n"
                "}\n"
            ),
        },
        set(),
    ),
)


def _strip_module_prefix(qn: str, path: str) -> str:
    """Reduce a dotted ``code_graph`` QN to its symbol part within ``path``."""
    stem = path.rsplit(".", 1)[0] if "." in path else path
    module_prefix = stem.replace("/", ".")
    if qn.startswith(f"{module_prefix}."):
        return qn[len(module_prefix) + 1 :]
    return qn


def _strip_scip_descriptor(qn: str) -> str:
    """Normalize a ``scip_ingest`` QN (``path::desc``) to ``Class.member``."""
    desc = qn.split("::", 1)[1] if "::" in qn else qn
    cleaned = desc.replace("`", "").strip()
    if cleaned.endswith("()."):
        cleaned = cleaned[:-3]
    elif cleaned.endswith((".", "#")):
        cleaned = cleaned[:-1]
    return cleaned.replace("#", ".").replace("/", ".")


def normalize_graph_calls(
    graph: CodeGraph,
    *,
    edge_type: str = "CALLS",
) -> set[NormalizedCall]:
    """Convert ``CodeGraph`` edges to representation-independent 4-tuples."""
    by_qn = {
        node.qualified_name: node
        for node in graph.nodes
        if node.label in ("Class", "Function")
    }
    normalized: set[NormalizedCall] = set()
    for edge in graph.edges:
        if edge.type != edge_type:
            continue
        src = by_qn.get(edge.source_qn)
        tgt = by_qn.get(edge.target_qn)
        if src is None or tgt is None or not src.path or not tgt.path:
            continue
        if edge_type == "REFERENCES":
            src_sym = _strip_scip_descriptor(src.qualified_name)
            tgt_sym = _strip_scip_descriptor(tgt.qualified_name)
        else:
            src_sym = _strip_module_prefix(src.qualified_name, src.path)
            tgt_sym = _strip_module_prefix(tgt.qualified_name, tgt.path)
        normalized.add((src.path, src_sym, tgt.path, tgt_sym))
    return normalized


def predicted_dart_calls(case: DartAccuracyCase) -> set[NormalizedCall]:
    """Parse one Dart fixture case via ``parse_repo`` and normalize CALLS."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for relative, source in case.files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        graph = parse_repo(root, repo_key="dart-accuracy-fixture")
    return normalize_graph_calls(graph, edge_type="CALLS")


def score_predictions(
    cases: tuple[DartAccuracyCase, ...],
    predict_fn: Any,
) -> dict[str, Any]:
    """Score any predictor returning ``set[NormalizedCall]`` on ``cases``.

    Reports ``precision: None`` when ``tp + fp == 0`` rather than a
    vacuous ``1.0`` so an empty graph is never misread as 100% precise.
    """
    per_case: list[dict[str, Any]] = []
    tp = fp = fn = 0
    for case in cases:
        predicted = set(predict_fn(case))
        expected = set(case.expected_calls)
        case_tp = len(predicted & expected)
        case_fp = len(predicted - expected)
        case_fn = len(expected - predicted)
        tp += case_tp
        fp += case_fp
        fn += case_fn
        per_case.append(
            {
                "id": case.id,
                "true_positives": case_tp,
                "false_positives": case_fp,
                "false_negatives": case_fn,
                "predicted": sorted(predicted),
                "expected": sorted(expected),
            }
        )
    precision = round(tp / (tp + fp), 4) if (tp + fp) else None
    recall = round(tp / (tp + fn), 4) if (tp + fn) else 1.0
    return {
        "cases": per_case,
        "true_positives": tp,
        "false_positives": fp,
        "false_negatives": fn,
        "precision": precision,
        "recall": recall,
    }


def evaluate_dart_cases(
    cases: tuple[DartAccuracyCase, ...] = CASES,
) -> dict[str, Any]:
    """Measure Dart call-edge precision/recall for ``parse_repo``."""
    return score_predictions(cases, predicted_dart_calls)


def summarize_dart_structural_stats(root: Path) -> dict[str, int]:
    """Summarize ``parse_repo`` Dart node/edge resolution stats on ``root``."""
    graph = parse_repo(root, repo_key="dart-structural-audit")
    dart_files = {
        n.path for n in graph.nodes if n.label == "CodeFile" and n.language == "dart"
    }
    dart_node_qns = {
        n.qualified_name for n in graph.nodes if n.language == "dart"
    }
    mod_qns = {n.qualified_name for n in graph.nodes if n.label == "CodeModule"}
    cls_qns = {n.qualified_name for n in graph.nodes if n.label == "Class"}
    dart_calls = [
        e
        for e in graph.edges
        if e.type == "CALLS" and e.source_qn in dart_node_qns
    ]
    dart_imports = [
        e
        for e in graph.edges
        if e.type == "IMPORTS" and e.source_qn in dart_node_qns
    ]
    dart_inherits = [
        e
        for e in graph.edges
        if e.type == "INHERITS" and e.source_qn in dart_node_qns
    ]
    return {
        "dart_files_parsed": len(dart_files),
        "dart_classes": sum(
            1 for n in graph.nodes if n.label == "Class" and n.language == "dart"
        ),
        "dart_functions": sum(
            1 for n in graph.nodes if n.label == "Function" and n.language == "dart"
        ),
        "dart_calls": len(dart_calls),
        "dart_imports_total": len(dart_imports),
        "dart_imports_resolved": sum(
            1 for e in dart_imports if e.target_qn in mod_qns
        ),
        "dart_inherits_total": len(dart_inherits),
        "dart_inherits_resolved": sum(
            1 for e in dart_inherits if e.target_qn in cls_qns
        ),
    }


if __name__ == "__main__":
    fixture_result = evaluate_dart_cases()
    app_root = Path(__file__).resolve().parents[2] / "app"
    summary: dict[str, Any] = {
        "fixture": {
            "case_count": len(CASES),
            "expected_edges": sum(len(c.expected_calls) for c in CASES),
            "true_positives": fixture_result["true_positives"],
            "false_positives": fixture_result["false_positives"],
            "false_negatives": fixture_result["false_negatives"],
            "precision": fixture_result["precision"],
            "recall": fixture_result["recall"],
        },
    }
    if app_root.is_dir():
        summary["app_structural"] = summarize_dart_structural_stats(app_root)
    print(json.dumps(summary, indent=2))
