"""Accuracy fixture for TypeScript / JavaScript code-graph call resolution.

Slice 2 of closing the code-intelligence ceiling gaps: a deterministic set of
13 TS/JS call patterns — relative imports, aliased imports, namespace imports,
``index.ts`` barrel re-exports, ``export { a as b }``, ``tsconfig.json`` path
aliases, arrow-function calls, class ``this.`` method calls, inheritance,
``new Class()`` instance calls, same-name collisions, and dynamic negative
controls.

Expected edges use the same representation-independent 4-tuple
``(caller_path, caller_symbol, callee_path, callee_symbol)`` as
``code_accuracy.py`` and ``dart_code_accuracy.py``.
"""

from __future__ import annotations

import json
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from backend.ingestion.code_graph import CodeGraph, parse_repo

NormalizedCall = tuple[str, str, str, str]


@dataclass(frozen=True)
class TsAccuracyCase:
    """One TypeScript/JavaScript micro-package fixture plus expected CALLS."""

    id: str
    files: dict[str, str]
    expected_calls: frozenset[NormalizedCall] = field(default_factory=frozenset)


def _case(
    case_id: str,
    files: dict[str, str],
    expected: set[NormalizedCall],
) -> TsAccuracyCase:
    return TsAccuracyCase(
        id=case_id,
        files=files,
        expected_calls=frozenset(expected),
    )


CASES: tuple[TsAccuracyCase, ...] = (
    _case(
        "direct-same-file",
        {
            "src/mod.ts": (
                "export function target(): void {}\n"
                "\n"
                "export function caller(): void {\n"
                "  target();\n"
                "}\n"
            ),
        },
        {("src/mod.ts", "caller", "src/mod.ts", "target")},
    ),
    _case(
        "arrow-function-call",
        {
            "src/arrows.ts": (
                "const helper = (x: number): number => x + 1;\n"
                "\n"
                "export const run = (): number => {\n"
                "  return helper(1);\n"
                "};\n"
            ),
        },
        {("src/arrows.ts", "run", "src/arrows.ts", "helper")},
    ),
    _case(
        "method-this-call",
        {
            "src/worker.ts": (
                "export class Worker {\n"
                "  run(): void {\n"
                "    this.build();\n"
                "  }\n"
                "  build(): void {}\n"
                "}\n"
            ),
        },
        {("src/worker.ts", "Worker.run", "src/worker.ts", "Worker.build")},
    ),
    _case(
        "relative-import-named",
        {
            "src/impl.ts": "export function target(): void {}\n",
            "src/app.ts": (
                "import { target } from './impl';\n"
                "export function main(): void {\n"
                "  target();\n"
                "}\n"
            ),
        },
        {("src/app.ts", "main", "src/impl.ts", "target")},
    ),
    _case(
        "relative-import-aliased",
        {
            "src/impl.ts": "export function target(): void {}\n",
            "src/app.ts": (
                "import { target as fn } from './impl';\n"
                "export function main(): void {\n"
                "  fn();\n"
                "}\n"
            ),
        },
        {("src/app.ts", "main", "src/impl.ts", "target")},
    ),
    _case(
        "namespace-import-call",
        {
            "src/impl.ts": "export function target(): void {}\n",
            "src/app.ts": (
                "import * as impl from './impl';\n"
                "export function main(): void {\n"
                "  impl.target();\n"
                "}\n"
            ),
        },
        {("src/app.ts", "main", "src/impl.ts", "target")},
    ),
    _case(
        "barrel-index-reexport",
        {
            "src/barrel/impl.ts": "export function target(): void {}\n",
            "src/barrel/index.ts": "export { target } from './impl';\n",
            "src/app.ts": (
                "import { target } from './barrel';\n"
                "export function main(): void {\n"
                "  target();\n"
                "}\n"
            ),
        },
        {("src/app.ts", "main", "src/barrel/impl.ts", "target")},
    ),
    _case(
        "barrel-export-alias",
        {
            "src/barrel/impl.ts": "export function target(): void {}\n",
            "src/barrel/index.ts": "export { target as renamed } from './impl';\n",
            "src/app.ts": (
                "import { renamed } from './barrel';\n"
                "export function main(): void {\n"
                "  renamed();\n"
                "}\n"
            ),
        },
        {("src/app.ts", "main", "src/barrel/impl.ts", "target")},
    ),
    _case(
        "tsconfig-path-alias",
        {
            "tsconfig.json": json.dumps(
                {
                    "compilerOptions": {
                        "baseUrl": ".",
                        "paths": {"@app/*": ["src/*"]},
                    }
                }
            ),
            "src/utils/math.ts": "export function add(a: number, b: number): number { return a + b; }\n",
            "src/app.ts": (
                "import { add } from '@app/utils/math';\n"
                "export function main(): number {\n"
                "  return add(1, 2);\n"
                "}\n"
            ),
        },
        {("src/app.ts", "main", "src/utils/math.ts", "add")},
    ),
    _case(
        "inheritance-super-method",
        {
            "src/base.ts": (
                "export class Base {\n"
                "  greet(): void {}\n"
                "}\n"
            ),
            "src/sub.ts": (
                "import { Base } from './base';\n"
                "export class Sub extends Base {\n"
                "  run(): void {\n"
                "    this.greet();\n"
                "  }\n"
                "}\n"
            ),
        },
        {("src/sub.ts", "Sub.run", "src/base.ts", "Base.greet")},
    ),
    _case(
        "cross-file-class-instantiation",
        {
            "src/service.ts": (
                "export class Service {\n"
                "  process(): void {}\n"
                "}\n"
            ),
            "src/app.ts": (
                "import { Service } from './service';\n"
                "export function main(): void {\n"
                "  const svc = new Service();\n"
                "  svc.process();\n"
                "}\n"
            ),
        },
        {("src/app.ts", "main", "src/service.ts", "Service.process")},
    ),
    _case(
        "same-name-collision",
        {
            "src/a.ts": "export function run(): void {}\n",
            "src/b.ts": "export function run(): void {}\n",
            "src/app.ts": (
                "import { run } from './a';\n"
                "export function main(): void {\n"
                "  run();\n"
                "}\n"
            ),
        },
        {("src/app.ts", "main", "src/a.ts", "run")},
    ),
    _case(
        "dynamic-negative-control",
        {
            "src/dyn.ts": (
                "const registry: Record<string, () => void> = {};\n"
                "export function dispatch(name: string): void {\n"
                "  const fn = registry[name];\n"
                "  fn();\n"
                "}\n"
            ),
        },
        set(),
    ),
)


def _normalize_symbol(node_path: str, qualified_name: str, name: str) -> str:
    """Reduce a node's qualified_name to Class.method or top-level function name."""
    stem = node_path.rsplit(".", 1)[0] if "." in node_path else node_path
    parts = [p for p in stem.split("/") if p]
    if parts and parts[0] == "src":
        parts = parts[1:]
    mod_qn = ".".join(parts)
    if mod_qn and qualified_name.startswith(mod_qn + "."):
        return qualified_name[len(mod_qn) + 1 :]
    return name


def extract_normalized_calls(graph: CodeGraph) -> set[NormalizedCall]:
    """Extract normalized (caller_path, caller_sym, callee_path, callee_sym) from CodeGraph."""
    by_qn = {n.qualified_name: n for n in graph.nodes}
    calls: set[NormalizedCall] = set()
    for edge in graph.edges:
        if edge.type != "CALLS":
            continue
        src = by_qn.get(edge.source_qn)
        dst = by_qn.get(edge.target_qn)
        if src is None or dst is None:
            continue
        calls.add(
            (
                src.path,
                _normalize_symbol(src.path, src.qualified_name, src.name),
                dst.path,
                _normalize_symbol(dst.path, dst.qualified_name, dst.name),
            )
        )
    return calls


def evaluate_ts_accuracy() -> dict[str, Any]:
    """Run all TS/JS accuracy cases through parse_repo and compute precision/recall."""
    tp = 0
    fp = 0
    fn = 0
    per_case: list[dict[str, Any]] = []
    for case in CASES:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel, content in case.files.items():
                p = root / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(content, encoding="utf-8")
            graph = parse_repo(root)
        got = extract_normalized_calls(graph)
        exp = set(case.expected_calls)
        case_tp = len(got & exp)
        case_fp = len(got - exp)
        case_fn = len(exp - got)
        tp += case_tp
        fp += case_fp
        fn += case_fn
        per_case.append(
            {
                "id": case.id,
                "tp": case_tp,
                "fp": case_fp,
                "fn": case_fn,
                "missing": sorted(exp - got),
                "extra": sorted(got - exp),
            }
        )
    precision = tp / (tp + fp) if (tp + fp) else 1.0
    recall = tp / (tp + fn) if (tp + fn) else 1.0
    return {
        "cases": len(CASES),
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "precision": round(precision, 4),
        "recall": round(recall, 4),
        "per_case": per_case,
    }


if __name__ == "__main__":
    print(json.dumps(evaluate_ts_accuracy(), indent=2))
