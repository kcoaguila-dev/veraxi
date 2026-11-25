"""Linter findings as claims (ADR-0007 Phase 2 / PR-pipeline WP3).

Runs ``ruff`` and ``mypy`` on *changed files only* and turns their
output into normalized finding dicts that ride the existing SARIF
path (:func:`backend.ingestion.sarif.parse_sarif_payload` /
:func:`backend.ingestion.sarif.write_sarif_findings`) — linter
results become graph claims next to scanner findings instead of a
parallel store.

Design rules (ADR-0007):

* Subprocess calls are argument lists only — never shell strings —
  each with a timeout. A tool that is missing, times out, or exits
  with a fatal status is reported to Sentry and yields no findings
  for that tool; it never crashes the caller.
* Ruff speaks SARIF natively (``--output-format sarif``). Mypy does
  not, so its JSON-lines output is converted into the same SARIF
  shape first.
* Everything is gated behind ``lint_findings_enabled`` (default
  off): running linters over uploaded / untrusted code is opt-in.

De-dupe seam: :func:`dedupe_review_comments` is a pure function
dropping an AI review comment that duplicates a linter finding
(same file, overlapping line range, same rule category). The
current review surface (CLI ``review`` -> LLM briefing engine)
produces free-text, not structured comments, so there is no
structured comment stream to wire it into yet; it is ready for the
PR-review pipeline (WP5) and is unit-tested standalone.
"""

from __future__ import annotations

import json
import logging
import re
import subprocess
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

import sentry_sdk

from backend.ingestion.sarif import parse_sarif_payload, write_sarif_findings

logger = logging.getLogger(__name__)

Runner = Callable[..., "subprocess.CompletedProcess[str]"]

_LEVEL_BY_SEVERITY = {"error": "error", "warning": "warning", "note": "note"}

# Ruff codes whose category is more specific than their letter family.
_RUFF_SPECIFIC_CATEGORIES = {
    "F401": "unused-import",
    "F811": "unused-import",
    "F841": "unused-variable",
    "E901": "syntax-error",
    "E902": "syntax-error",
    "F701": "syntax-error",
    "F702": "syntax-error",
    "F704": "syntax-error",
    "F706": "syntax-error",
    "F707": "syntax-error",
}
_RUFF_PREFIX_RE = re.compile(r"^([A-Z]+)\d+$")


def rule_category(tool: str, rule_id: str) -> str:
    """Canonical rule category for a linter finding or review comment.

    Mypy findings are all type errors (the specific code stays in
    ``rule_id``). Ruff codes map to a specific category for the
    well-known noise rules and to their letter family otherwise.
    """
    rule = (rule_id or "").strip()
    if (tool or "").lower() == "mypy":
        return "type-error"
    if rule in _RUFF_SPECIFIC_CATEGORIES:
        return _RUFF_SPECIFIC_CATEGORIES[rule]
    match = _RUFF_PREFIX_RE.match(rule)
    if match:
        return f"ruff-{match.group(1).lower()}"
    return rule.lower() or "unknown"


def _comment_category(comment: dict[str, Any]) -> str | None:
    """Category of an AI review comment, or None when it has none.

    A comment with no derivable category can never be de-duped —
    dropping it on a guess would hide a real review point.
    """
    explicit = str(comment.get("category") or "").strip().lower()
    if explicit:
        return explicit
    rule_id = str(comment.get("rule_id") or "").strip()
    if not rule_id:
        return None
    tool = str(comment.get("tool") or "").strip()
    if not tool:
        # Mypy codes are kebab-case words; ruff codes are CAPS+digits.
        tool = "ruff" if _RUFF_PREFIX_RE.match(rule_id) else "mypy"
    return rule_category(tool, rule_id)


def _line_range(item: dict[str, Any]) -> tuple[int, int] | None:
    try:
        start = int(item.get("line") or 0)
    except (TypeError, ValueError):
        return None
    if start <= 0:
        return None
    try:
        end = int(item.get("end_line") or start)
    except (TypeError, ValueError):
        end = start
    return (start, max(start, end))


def _ranges_overlap(a: tuple[int, int], b: tuple[int, int]) -> bool:
    return a[0] <= b[1] and b[0] <= a[1]


def dedupe_review_comments(
    comments: Sequence[dict[str, Any]],
    findings: Sequence[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Split review comments into (kept, dropped) against lint findings.

    Pure. A comment is dropped only when a linter finding exists on
    the same file, with an overlapping line range, in the same rule
    category — the deterministic tool already made that claim, so
    the AI repeating it adds noise, not signal.
    """
    indexed: list[tuple[str, tuple[int, int], str]] = []
    for finding in findings:
        rng = _line_range(finding)
        path = str(finding.get("path") or "")
        if rng is None or not path:
            continue
        category = str(finding.get("category") or "") or rule_category(
            str(finding.get("tool") or ""), str(finding.get("rule_id") or "")
        )
        indexed.append((path, rng, category))

    kept: list[dict[str, Any]] = []
    dropped: list[dict[str, Any]] = []
    for comment in comments:
        if _is_duplicate(comment, indexed):
            dropped.append(comment)
        else:
            kept.append(comment)
    return kept, dropped


def _is_duplicate(
    comment: dict[str, Any],
    indexed: list[tuple[str, tuple[int, int], str]],
) -> bool:
    category = _comment_category(comment)
    rng = _line_range(comment)
    path = str(comment.get("path") or comment.get("file") or "")
    if category is None or rng is None or not path:
        return False
    return any(
        f_path == path and f_category == category and _ranges_overlap(f_rng, rng)
        for f_path, f_rng, f_category in indexed
    )


def _relative_path(raw: str, root: Path) -> str:
    """Normalize a tool-reported path to a repo-relative POSIX path."""
    text = (raw or "").strip().removeprefix("file://")
    path = Path(text)
    if path.is_absolute():
        try:
            path = path.relative_to(root)
        except ValueError:
            return path.as_posix()
    return path.as_posix()


def _run_tool(
    argv: list[str], *, timeout: int, runner: Runner, cwd: Path
) -> subprocess.CompletedProcess[str] | None:
    """Run one linter; on any failure report to Sentry and return None."""
    try:
        return runner(
            argv, capture_output=True, text=True, timeout=timeout, cwd=str(cwd)
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        logger.warning("Linter %s failed to run: %s", argv[0], exc)
        sentry_sdk.capture_exception(exc)
        return None


def run_ruff_sarif(
    files: Sequence[str], *, root: Path, timeout: int, runner: Runner = subprocess.run
) -> dict[str, Any] | None:
    """Run ruff on ``files`` and return its SARIF payload (or None)."""
    if not files:
        return None
    argv = ["ruff", "check", "--output-format", "sarif", "--no-cache", *files]
    result = _run_tool(argv, timeout=timeout, runner=runner, cwd=root)
    if result is None:
        return None
    if result.returncode not in (0, 1):
        exc = RuntimeError(
            f"ruff exited {result.returncode}: {(result.stderr or '')[:500]}"
        )
        logger.warning("%s", exc)
        sentry_sdk.capture_exception(exc)
        return None
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        logger.warning("ruff SARIF output was not JSON: %s", exc)
        sentry_sdk.capture_exception(exc)
        return None
    return payload if isinstance(payload, dict) else None


def run_mypy_json_lines(
    files: Sequence[str], *, root: Path, timeout: int, runner: Runner = subprocess.run
) -> list[dict[str, Any]]:
    """Run mypy on ``files`` and return its parsed JSON-lines records."""
    if not files:
        return []
    argv = [
        "mypy",
        "--output",
        "json",
        "--no-error-summary",
        "--ignore-missing-imports",
        "--no-incremental",
        *files,
    ]
    result = _run_tool(argv, timeout=timeout, runner=runner, cwd=root)
    if result is None:
        return []
    if result.returncode not in (0, 1):
        exc = RuntimeError(
            f"mypy exited {result.returncode}: {(result.stderr or '')[:500]}"
        )
        logger.warning("%s", exc)
        sentry_sdk.capture_exception(exc)
        return []
    records: list[dict[str, Any]] = []
    for line in (result.stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def mypy_records_to_sarif(records: Sequence[dict[str, Any]], *, root: Path) -> dict[str, Any]:
    """Convert mypy JSON records into a SARIF 2.1.0 payload dict."""
    rules: dict[str, dict[str, Any]] = {}
    results: list[dict[str, Any]] = []
    for record in records:
        code = str(record.get("code") or "error")
        rules.setdefault(
            code,
            {"id": code, "shortDescription": {"text": f"mypy {code}"}},
        )
        line = int(record.get("line") or 0)
        end_line = int(record.get("end_line") or line)
        severity = str(record.get("severity") or "error").lower()
        results.append(
            {
                "ruleId": code,
                "level": _LEVEL_BY_SEVERITY.get(severity, "error"),
                "message": {"text": str(record.get("message") or "")},
                "locations": [
                    {
                        "physicalLocation": {
                            "artifactLocation": {
                                "uri": _relative_path(
                                    str(record.get("file") or ""), root
                                )
                            },
                            "region": {"startLine": line, "endLine": end_line},
                        }
                    }
                ],
            }
        )
    return {
        "version": "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "runs": [
            {
                "tool": {"driver": {"name": "mypy", "rules": list(rules.values())}},
                "results": results,
            }
        ],
    }


def _normalize_ruff_sarif(payload: dict[str, Any], *, root: Path) -> dict[str, Any]:
    """Rewrite ruff's absolute ``file://`` artifact URIs as repo-relative."""
    for run in payload.get("runs") or []:
        for result in run.get("results") or []:
            for location in result.get("locations") or []:
                phys = location.get("physicalLocation") or {}
                artifact = phys.get("artifactLocation") or {}
                if artifact.get("uri"):
                    artifact["uri"] = _relative_path(str(artifact["uri"]), root)
    return payload


def _with_ranges_and_categories(
    parsed: list[dict[str, Any]], sarif_payload: dict[str, Any], tool: str
) -> list[dict[str, Any]]:
    """Re-attach end lines + categories the SARIF parser does not keep.

    ``parse_sarif_payload`` normalizes tool/rule/severity/message/
    path/line; regions' ``endLine`` is read back from the payload in
    result order so findings carry a real line range for de-dupe.
    """
    end_lines: list[int] = []
    for run in sarif_payload.get("runs") or []:
        for result in run.get("results") or []:
            locations = result.get("locations") or []
            region = (locations[0].get("physicalLocation") or {}).get("region") or {} if locations else {}
            end_lines.append(int(region.get("endLine") or region.get("startLine") or 0))
    findings: list[dict[str, Any]] = []
    for idx, finding in enumerate(parsed):
        end_line = end_lines[idx] if idx < len(end_lines) else 0
        enriched = dict(finding)
        enriched["end_line"] = max(int(finding.get("line") or 0), end_line)
        enriched["category"] = rule_category(tool, str(finding.get("rule_id") or ""))
        findings.append(enriched)
    return findings


def collect_lint_findings(
    files: Sequence[str],
    *,
    root: str | Path,
    timeout: int = 60,
    runner: Runner = subprocess.run,
) -> list[dict[str, Any]]:
    """Run ruff + mypy over ``files`` and return normalized findings.

    Each finding: ``tool``, ``rule_id``, ``category``, ``severity``,
    ``message``, ``path``, ``line``, ``end_line``, ``cwe_ids``,
    ``taint_path`` — the SARIF parser's shape plus range/category.
    """
    root_path = Path(root)
    py_files = [str(f) for f in files if str(f).endswith(".py")]
    findings: list[dict[str, Any]] = []
    if not py_files:
        return findings
    ruff_payload = run_ruff_sarif(py_files, root=root_path, timeout=timeout, runner=runner)
    if ruff_payload is not None:
        normalized = _normalize_ruff_sarif(ruff_payload, root=root_path)
        findings.extend(
            _with_ranges_and_categories(
                parse_sarif_payload(normalized), normalized, "ruff"
            )
        )
    mypy_records = run_mypy_json_lines(py_files, root=root_path, timeout=timeout, runner=runner)
    if mypy_records:
        mypy_sarif = mypy_records_to_sarif(mypy_records, root=root_path)
        findings.extend(
            _with_ranges_and_categories(
                parse_sarif_payload(mypy_sarif), mypy_sarif, "mypy"
            )
        )
    return findings


def build_sarif_payload(findings: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """Rebuild a SARIF 2.1.0 payload from normalized lint findings.

    This is the bridge into the existing SARIF write path: the
    payload parses cleanly through ``parse_sarif_payload`` and
    persists through ``write_sarif_findings`` unchanged.
    """
    runs: list[dict[str, Any]] = []
    by_tool: dict[str, list[dict[str, Any]]] = {}
    for finding in findings:
        by_tool.setdefault(str(finding.get("tool") or "lint"), []).append(finding)
    severity_to_level = {"HIGH": "error", "MEDIUM": "warning", "LOW": "note", "INFO": "none"}
    for tool, tool_findings in by_tool.items():
        rules = {
            str(f.get("rule_id") or "unknown"): {
                "id": str(f.get("rule_id") or "unknown"),
                "shortDescription": {"text": str(f.get("rule_id") or "unknown")},
            }
            for f in tool_findings
        }
        results = [
            {
                "ruleId": str(f.get("rule_id") or "unknown"),
                "level": severity_to_level.get(
                    str(f.get("severity") or "MEDIUM").upper(), "warning"
                ),
                "message": {"text": str(f.get("message") or "")},
                "locations": [
                    {
                        "physicalLocation": {
                            "artifactLocation": {"uri": str(f.get("path") or "")},
                            "region": {
                                "startLine": int(f.get("line") or 0),
                                "endLine": int(f.get("end_line") or f.get("line") or 0),
                            },
                        }
                    }
                ],
            }
            for f in tool_findings
        ]
        runs.append(
            {
                "tool": {"driver": {"name": tool, "rules": list(rules.values())}},
                "results": results,
            }
        )
    return {
        "version": "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "runs": runs,
    }


def ingest_lint_findings(
    neo4j_client: Any,
    files: Sequence[str],
    *,
    root: str | Path,
    tenant_id: str = "default",
    qdrant_client: Any = None,
    timeout: int | None = None,
    runner: Runner = subprocess.run,
) -> dict[str, Any]:
    """Collect lint findings on ``files`` and persist them via SARIF.

    Gated by ``lint_findings_enabled`` (default off). Returns a
    summary dict; when disabled or when both tools fail, nothing is
    written and no exception escapes.
    """
    from backend.config import get_config

    config = get_config()
    if not config.lint_findings_enabled:
        return {"enabled": False, "findings": 0, "findings_written": 0}
    findings = collect_lint_findings(
        files,
        root=root,
        timeout=timeout if timeout is not None else config.lint_timeout_sec,
        runner=runner,
    )
    if not findings:
        return {"enabled": True, "findings": 0, "findings_written": 0}
    parsed = parse_sarif_payload(build_sarif_payload(findings))
    counts = write_sarif_findings(
        neo4j_client, parsed, tenant_id=tenant_id, qdrant_client=qdrant_client
    )
    return {"enabled": True, "findings": len(findings), **counts}


__all__ = [
    "build_sarif_payload",
    "collect_lint_findings",
    "dedupe_review_comments",
    "ingest_lint_findings",
    "mypy_records_to_sarif",
    "rule_category",
    "run_mypy_json_lines",
    "run_ruff_sarif",
]
