"""Baseline accuracy fixture for Python code-graph call resolution.

Phase 16 (ADR-0007) groundwork: a small, deterministic set of tricky
Python cases — assignment aliases, ``__init__`` re-exports,
``from x import y as _y``, function-local imports, same-name
collisions, and the ``build_video_item`` / ``_build_video_item``
dogfood pattern — run through the real :func:`parse_repo` extraction.

Each case declares the exact ``CALLS`` edges it should produce.
:func:`evaluate_cases` reports call-edge precision / recall against
those expectations; every later accuracy phase is measured against
this fixture instead of against estimates.

Pure and offline: fixture sources are written to a temporary
directory and parsed in memory. No database, network or LLM.
"""

from __future__ import annotations

import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from backend.ingestion.code_graph import parse_repo


@dataclass(frozen=True)
class AccuracyCase:
    """One fixture repo plus the CALLS edges it must produce."""

    id: str
    files: dict[str, str]
    expected_calls: frozenset[tuple[str, str]] = field(default_factory=frozenset)


def _case(
    case_id: str, files: dict[str, str], expected: set[tuple[str, str]]
) -> AccuracyCase:
    return AccuracyCase(id=case_id, files=files, expected_calls=frozenset(expected))


CASES: tuple[AccuracyCase, ...] = (
    _case(
        "direct-same-file",
        {"mod.py": "def target():\n    pass\n\n\ndef caller():\n    target()\n"},
        {("mod.caller", "mod.target")},
    ),
    _case(
        "from-import-plain",
        {
            "impl.py": "def target():\n    pass\n",
            "caller.py": (
                "from impl import target\n\n\ndef caller():\n    target()\n"
            ),
        },
        {("caller.caller", "impl.target")},
    ),
    _case(
        "from-import-as-private-name",
        {
            "impl.py": "def build_video_item():\n    pass\n",
            "caller.py": (
                "from impl import build_video_item as _build_video_item\n"
                "\n\ndef caller():\n    _build_video_item()\n"
            ),
        },
        {("caller.caller", "impl.build_video_item")},
    ),
    _case(
        "module-import-as-attribute",
        {
            "impl.py": "def target():\n    pass\n",
            "caller.py": (
                "import impl as im\n\n\ndef caller():\n    im.target()\n"
            ),
        },
        {("caller.caller", "impl.target")},
    ),
    _case(
        "assignment-alias-same-file",
        {
            "mod.py": (
                "def _build_video_item():\n    pass\n"
                "\n\nbuild_video_item = _build_video_item\n"
                "\n\ndef caller():\n    build_video_item()\n"
            )
        },
        {("mod.caller", "mod._build_video_item")},
    ),
    _case(
        "assignment-alias-of-import",
        {
            "impl.py": "def build_video_item():\n    pass\n",
            "caller.py": (
                "from impl import build_video_item\n"
                "\n\n_build_video_item = build_video_item\n"
                "\n\ndef caller():\n    _build_video_item()\n"
            ),
        },
        {("caller.caller", "impl.build_video_item")},
    ),
    _case(
        "assignment-alias-called-directly",
        {
            "mod.py": (
                "def target():\n    pass\n"
                "\n\nalias_fn = target\n"
                "\n\ndef caller():\n    alias_fn()\n"
            )
        },
        {("mod.caller", "mod.target")},
    ),
    _case(
        "init-reexport-plain",
        {
            "pkg/__init__.py": "from .impl import build_video_item\n",
            "pkg/impl.py": "def build_video_item():\n    pass\n",
            "caller.py": (
                "from pkg import build_video_item\n"
                "\n\ndef caller():\n    build_video_item()\n"
            ),
        },
        {("caller.caller", "pkg.impl.build_video_item")},
    ),
    _case(
        "init-reexport-renamed-dogfood",
        {
            "pkg/__init__.py": (
                "from .impl import build_video_item as _build_video_item\n"
            ),
            "pkg/impl.py": "def build_video_item():\n    pass\n",
            "caller.py": (
                "from pkg import _build_video_item\n"
                "\n\ndef caller():\n    _build_video_item()\n"
            ),
        },
        {("caller.caller", "pkg.impl.build_video_item")},
    ),
    _case(
        "init-assignment-reexport",
        {
            "pkg/__init__.py": (
                "from .impl import build_video_item as _bvi\n"
                "\nbuild_video_item = _bvi\n"
            ),
            "pkg/impl.py": "def build_video_item():\n    pass\n",
            "caller.py": (
                "from pkg import build_video_item\n"
                "\n\ndef caller():\n    build_video_item()\n"
            ),
        },
        {("caller.caller", "pkg.impl.build_video_item")},
    ),
    _case(
        "chained-reexport-two-packages",
        {
            "pkg/__init__.py": "from .sub import build_video_item\n",
            "pkg/sub.py": "from .impl import build_video_item\n",
            "pkg/impl.py": "def build_video_item():\n    pass\n",
            "caller.py": (
                "from pkg import build_video_item\n"
                "\n\ndef caller():\n    build_video_item()\n"
            ),
        },
        {("caller.caller", "pkg.impl.build_video_item")},
    ),
    _case(
        "function-local-import",
        {
            "impl.py": "def target():\n    pass\n",
            "caller.py": (
                "def caller():\n    from impl import target\n    target()\n"
            ),
        },
        {("caller.caller", "impl.target")},
    ),
    _case(
        "function-local-import-as",
        {
            "impl.py": "def build_video_item():\n    pass\n",
            "caller.py": (
                "def caller():\n"
                "    from impl import build_video_item as _build_video_item\n"
                "    _build_video_item()\n"
            ),
        },
        {("caller.caller", "impl.build_video_item")},
    ),
    _case(
        "same-name-collision-cross-module",
        {
            "alpha.py": "def shout():\n    pass\n\n\ndef call_alpha():\n    shout()\n",
            "beta.py": "def shout():\n    pass\n\n\ndef call_beta():\n    shout()\n",
            "caller.py": (
                "from alpha import shout as alpha_shout\n"
                "from beta import shout as beta_shout\n"
                "\n\ndef caller():\n    alpha_shout()\n    beta_shout()\n"
            ),
        },
        {
            ("alpha.call_alpha", "alpha.shout"),
            ("beta.call_beta", "beta.shout"),
            ("caller.caller", "alpha.shout"),
            ("caller.caller", "beta.shout"),
        },
    ),
    _case(
        "unresolved-call-produces-no-edge",
        {
            "mod.py": (
                "def caller(obj):\n    obj.mystery()\n    unknown_name()\n"
            )
        },
        set(),
    ),
    _case(
        "self-method-call",
        {
            "mod.py": (
                "class Worker:\n"
                "    def run(self):\n        return self.build()\n"
                "\n    def build(self):\n        pass\n"
            )
        },
        {("mod.Worker.run", "mod.Worker.build")},
    ),
)


def predicted_calls(case: AccuracyCase) -> set[tuple[str, str]]:
    """Parse one fixture case and return its CALLS edges as (source, target)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for relative, source in case.files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        graph = parse_repo(root, repo_key="accuracy-fixture")
    return {
        (edge.source_qn, edge.target_qn)
        for edge in graph.edges
        if edge.type == "CALLS"
    }


def evaluate_cases(cases: tuple[AccuracyCase, ...] = CASES) -> dict:
    """Measure call-edge precision/recall of ``cases`` against expectations."""
    per_case: list[dict] = []
    tp = fp = fn = 0
    for case in cases:
        predicted = predicted_calls(case)
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
    precision = tp / (tp + fp) if (tp + fp) else 1.0
    recall = tp / (tp + fn) if (tp + fn) else 1.0
    return {
        "cases": per_case,
        "true_positives": tp,
        "false_positives": fp,
        "false_negatives": fn,
        "precision": round(precision, 4),
        "recall": round(recall, 4),
    }
