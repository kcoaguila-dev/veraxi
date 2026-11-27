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

_DART_SPECIFIC_CATEGORIES = {
    "unused_import": "unused-import",
    "duplicate_import": "unused-import",
    "unused_local_variable": "unused-variable",
    "unused_field": "unused-variable",
    "unused_element": "unused-variable",
    "invalid_assignment": "type-error",
    "argument_type_not_assignable": "type-error",
    "return_of_invalid_type": "type-error",
    "undefined_identifier": "type-error",
    "undefined_method": "type-error",
    "undefined_getter": "type-error",
}

_ESLINT_SPECIFIC_CATEGORIES = {
    "no-unused-vars": "unused-variable",
    "@typescript-eslint/no-unused-vars": "unused-variable",
    "no-undef": "type-error",
    "no-unreachable": "unreachable-code",
}


def rule_category(tool: str, rule_id: str) -> str:
    """Canonical rule category for a linter finding or review comment.

    Mypy findings are all type errors (the specific code stays in
    ``rule_id``). Ruff, Dart analyzer, and ESLint codes map to shared
    categories for well-known rules so cross-language de-duplication
    works uniformly.
    """
    rule = (rule_id or "").strip()
    tool_key = (tool or "").lower()
    if tool_key == "mypy":
        return "type-error"
    if tool_key == "dart":
        if rule in _DART_SPECIFIC_CATEGORIES:
            return _DART_SPECIFIC_CATEGORIES[rule]
        return f"dart-{rule.replace('_', '-').lower()}" if rule else "unknown"
    if tool_key == "eslint":
        if rule in _ESLINT_SPECIFIC_CATEGORIES:
            return _ESLINT_SPECIFIC_CATEGORIES[rule]
        return f"eslint-{rule.lower()}" if rule else "unknown"
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
    argv: list[str],
    *,
    timeout: int,
    runner: Runner,
    cwd: Path,
    optional: bool = False,
) -> subprocess.CompletedProcess[str] | None:
    """Run one linter; on failure report to Sentry (unless optional binary missing)."""
    try:
        return runner(
            argv, capture_output=True, text=True, timeout=timeout, cwd=str(cwd)
        )
    except FileNotFoundError as exc:
        if optional:
            logger.debug("Optional linter %s not installed: %s", argv[0], exc)
            return None
        logger.warning("Linter %s failed to run: %s", argv[0], exc)
        sentry_sdk.capture_exception(exc)
        return None
    except (subprocess.TimeoutExpired, OSError) as exc:
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
    files: Sequence[str],
    *,
    root: Path,
    timeout: int,
    runner: Runner = subprocess.run,
    safe_mode: bool = True,
) -> list[dict[str, Any]]:
    """Run mypy on ``files`` and return its parsed JSON-lines records.

    When ``safe_mode`` is True (default), ``--config-file=/dev/null`` and
    ``--follow-imports=silent`` prevent untrusted repo configs from loading
    arbitrary mypy plugins.
    """
    if not files:
        return []
    argv = [
        "mypy",
        "--output",
        "json",
        "--no-error-summary",
        "--ignore-missing-imports",
        "--no-incremental",
    ]
    if safe_mode:
        argv.extend(["--config-file=/dev/null", "--follow-imports=silent"])
    argv.extend(files)
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


def parse_lint_sarif(
    sarif_payload: dict[str, Any], *, root: str | Path | None = None
) -> list[dict[str, Any]]:
    """Parse an uploaded SARIF 2.1.0 payload into normalized lint findings."""
    if not isinstance(sarif_payload, dict):
        return []
    runs = sarif_payload.get("runs") or []
    if not isinstance(runs, list):
        return []
    findings: list[dict[str, Any]] = []
    root_path = Path(root) if root is not None else None
    for run in runs:
        if not isinstance(run, dict):
            continue
        driver = (run.get("tool") or {}).get("driver") or {}
        tool = str(driver.get("name") or "lint")
        single_run = {"version": sarif_payload.get("version", "2.1.0"), "runs": [run]}
        if root_path is not None:
            single_run = _normalize_ruff_sarif(single_run, root=root_path)
        findings.extend(
            _with_ranges_and_categories(
                parse_sarif_payload(single_run), single_run, tool
            )
        )
    return findings


def _sarif_envelope(
    tool_name: str, rules: dict[str, dict[str, Any]], results: list[dict[str, Any]]
) -> dict[str, Any]:
    return {
        "version": "2.1.0",
        "runs": [
            {
                "tool": {"driver": {"name": tool_name, "rules": list(rules.values())}},
                "results": results,
            }
        ],
    }


def _sarif_location(path: str, start_line: int, end_line: int) -> dict[str, Any]:
    return {
        "physicalLocation": {
            "artifactLocation": {"uri": path},
            "region": {
                "startLine": max(1, start_line),
                "endLine": max(1, end_line, start_line),
            },
        }
    }


def run_dart_analyze_json(
    files: Sequence[str], *, root: Path, timeout: int, runner: Runner = subprocess.run
) -> list[dict[str, Any]]:
    """Run ``dart analyze --format json`` on ``files`` and return diagnostics."""
    if not files:
        return []
    argv = ["dart", "analyze", "--format", "json", *files]
    result = _run_tool(argv, timeout=timeout, runner=runner, cwd=root, optional=True)
    if result is None:
        return []
    # dart analyze exits 0 (clean), 1 (info), 2 (warning), 3 (error).
    if result.returncode not in (0, 1, 2, 3):
        exc = RuntimeError(
            f"dart analyze exited {result.returncode}: {(result.stderr or '')[:500]}"
        )
        logger.warning("%s", exc)
        sentry_sdk.capture_exception(exc)
        return []
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        logger.warning("dart analyze JSON output was invalid: %s", exc)
        sentry_sdk.capture_exception(exc)
        return []
    diagnostics = payload.get("diagnostics") if isinstance(payload, dict) else None
    return [d for d in (diagnostics or []) if isinstance(d, dict)]


def dart_diagnostics_to_sarif(
    diagnostics: Sequence[dict[str, Any]], *, root: Path
) -> dict[str, Any]:
    """Convert ``dart analyze --format json`` diagnostics into SARIF 2.1.0."""
    severity_map = {"ERROR": "error", "WARNING": "warning", "INFO": "note"}
    rules: dict[str, dict[str, Any]] = {}
    results: list[dict[str, Any]] = []
    for diag in diagnostics:
        code = str(diag.get("code") or "dart_error")
        rules.setdefault(code, {"id": code, "shortDescription": {"text": f"dart {code}"}})
        loc = diag.get("location") or {}
        rng = loc.get("range") or {}
        start = int((rng.get("start") or {}).get("line") or 0)
        end = int((rng.get("end") or {}).get("line") or start)
        level = severity_map.get(str(diag.get("severity") or "").upper(), "warning")
        results.append(
            {
                "ruleId": code,
                "level": level,
                "message": {"text": str(diag.get("problemMessage") or "")},
                "locations": [_sarif_location(_relative_path(str(loc.get("file") or ""), root), start, end)],
            }
        )
    return _sarif_envelope("dart", rules, results)


def run_eslint_json(
    files: Sequence[str], *, root: Path, timeout: int, runner: Runner = subprocess.run
) -> list[dict[str, Any]]:
    """Run ``eslint --format json`` on ``files`` and return parsed file records."""
    if not files:
        return []
    argv = ["eslint", "--format", "json", *files]
    result = _run_tool(argv, timeout=timeout, runner=runner, cwd=root, optional=True)
    if result is None:
        return []
    if result.returncode not in (0, 1):
        exc = RuntimeError(
            f"eslint exited {result.returncode}: {(result.stderr or '')[:500]}"
        )
        logger.warning("%s", exc)
        sentry_sdk.capture_exception(exc)
        return []
    try:
        payload = json.loads(result.stdout or "[]")
    except json.JSONDecodeError as exc:
        logger.warning("eslint JSON output was invalid: %s", exc)
        sentry_sdk.capture_exception(exc)
        return []
    return [r for r in payload if isinstance(r, dict)] if isinstance(payload, list) else []


def eslint_records_to_sarif(
    records: Sequence[dict[str, Any]], *, root: Path
) -> dict[str, Any]:
    """Convert ``eslint --format json`` records into SARIF 2.1.0."""
    rules: dict[str, dict[str, Any]] = {}
    results: list[dict[str, Any]] = []
    for file_rec in records:
        rel_path = _relative_path(str(file_rec.get("filePath") or ""), root)
        for msg in file_rec.get("messages") or []:
            if not isinstance(msg, dict):
                continue
            code = str(msg.get("ruleId") or "eslint-error")
            rules.setdefault(code, {"id": code, "shortDescription": {"text": f"eslint {code}"}})
            start = int(msg.get("line") or 0)
            end = int(msg.get("endLine") or start)
            level = "error" if int(msg.get("severity") or 1) >= 2 else "warning"
            results.append(
                {
                    "ruleId": code,
                    "level": level,
                    "message": {"text": str(msg.get("message") or "")},
                    "locations": [_sarif_location(rel_path, start, end)],
                }
            )
    return _sarif_envelope("eslint", rules, results)


def _collect_python_sarif_runs(
    files: Sequence[str],
    *,
    root: Path,
    timeout: int,
    runner: Runner,
    safe_mode: bool,
) -> list[tuple[str, dict[str, Any]]]:
    runs: list[tuple[str, dict[str, Any]]] = []
    ruff_payload = run_ruff_sarif(files, root=root, timeout=timeout, runner=runner)
    if ruff_payload is not None:
        runs.append(("ruff", _normalize_ruff_sarif(ruff_payload, root=root)))
    mypy_records = run_mypy_json_lines(
        files, root=root, timeout=timeout, runner=runner, safe_mode=safe_mode
    )
    if mypy_records:
        runs.append(("mypy", mypy_records_to_sarif(mypy_records, root=root)))
    return runs


def _collect_dart_sarif_runs(
    files: Sequence[str], *, root: Path, timeout: int, runner: Runner, **_kwargs: Any
) -> list[tuple[str, dict[str, Any]]]:
    diagnostics = run_dart_analyze_json(files, root=root, timeout=timeout, runner=runner)
    return [("dart", dart_diagnostics_to_sarif(diagnostics, root=root))] if diagnostics else []


def _collect_js_ts_sarif_runs(
    files: Sequence[str], *, root: Path, timeout: int, runner: Runner, **_kwargs: Any
) -> list[tuple[str, dict[str, Any]]]:
    records = run_eslint_json(files, root=root, timeout=timeout, runner=runner)
    if not records:
        return []
    sarif = eslint_records_to_sarif(records, root=root)
    return [("eslint", sarif)] if sarif["runs"][0]["results"] else []


_LINTER_ADAPTERS: tuple[tuple[tuple[str, ...], Callable[..., list[tuple[str, dict[str, Any]]]]], ...] = (
    ((".py",), _collect_python_sarif_runs),
    ((".dart",), _collect_dart_sarif_runs),
    ((".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx"), _collect_js_ts_sarif_runs),
)


def collect_lint_findings(
    files: Sequence[str],
    *,
    root: str | Path,
    timeout: int = 60,
    runner: Runner = subprocess.run,
    safe_mode: bool = True,
) -> list[dict[str, Any]]:
    """Run configured language linters over ``files`` and return findings.

    Dispatches changed files by extension across Python (``ruff`` +
    ``mypy``), Dart (``dart analyze``), and JS/TS (``eslint``),
    normalizing every tool into the shared SARIF shape: ``tool``,
    ``rule_id``, ``category``, ``severity``, ``message``, ``path``,
    ``line``, ``end_line``, ``cwe_ids``, ``taint_path``.
    """
    root_path = Path(root)
    findings: list[dict[str, Any]] = []
    for extensions, adapter in _LINTER_ADAPTERS:
        matching = [str(f) for f in files if str(f).lower().endswith(extensions)]
        if not matching:
            continue
        for tool, sarif in adapter(
            matching, root=root_path, timeout=timeout, runner=runner, safe_mode=safe_mode
        ):
            findings.extend(
                _with_ranges_and_categories(parse_sarif_payload(sarif), sarif, tool)
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
    safe_mode: bool = True,
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
        safe_mode=safe_mode,
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
    "dart_diagnostics_to_sarif",
    "dedupe_review_comments",
    "eslint_records_to_sarif",
    "ingest_lint_findings",
    "mypy_records_to_sarif",
    "parse_lint_sarif",
    "rule_category",
    "run_dart_analyze_json",
    "run_eslint_json",
    "run_mypy_json_lines",
    "run_ruff_sarif",
]
