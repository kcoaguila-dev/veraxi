"""Structured PR/diff review orchestrator (ADR-0007 Phase 2 / WP5).

Combines graph reachability context (:func:`audit_diff_files`),
deterministic linter claims (:mod:`backend.ingestion.lint_findings`),
and structured AI review comments, deduplicating overlapping AI comments
against linter findings via :func:`dedupe_review_comments`.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Callable, Sequence
from typing import Any, Literal, cast

import sentry_sdk
from pydantic import BaseModel, Field

from backend.ingestion.lint_findings import (
    build_sarif_payload,
    collect_lint_findings,
    dedupe_review_comments,
    parse_lint_sarif,
)
from backend.ingestion.sarif import parse_sarif_payload, write_sarif_findings
from backend.retrieval.vuln_queries import audit_diff_files

logger = logging.getLogger(__name__)

Severity = Literal["HIGH", "MEDIUM", "LOW", "INFO"]
CommentSource = Literal["ai", "linter", "sast", "rule"]
AiReviewer = Callable[[str, list[str], list[dict[str, Any]]], list[dict[str, Any]]]

_VALID_SEVERITIES = {"HIGH", "MEDIUM", "LOW", "INFO"}
_DIFF_PREVIEW_CHARS = 16000


class ReviewComment(BaseModel):
    """Single structured review comment anchored to a file and line range."""

    path: str = Field(..., min_length=1)
    line: int = Field(..., ge=1)
    end_line: int = Field(default=1, ge=1)
    severity: Severity = "MEDIUM"
    category: str = Field(..., min_length=1)
    rule_id: str | None = None
    tool: str | None = None
    message: str = Field(..., min_length=1)
    suggestion: str | None = None
    source: CommentSource = "ai"
    evidence: list[dict[str, Any]] = Field(default_factory=list)


class ReviewRequest(BaseModel):
    """Request payload for ``POST /api/v1/code/review``."""

    diff: str = ""
    files: list[str] = Field(default_factory=list)
    repo: str | None = None
    lint_sarif: dict[str, Any] | None = None
    run_server_lint: bool = False
    root: str | None = None
    persist_lint_findings: bool = False
    include_ai_review: bool = True


class ReviewSummary(BaseModel):
    """Aggregate counts and dedupe metrics for a structured review."""

    files_count: int
    reachable_symbol_count: int
    sast_finding_count: int
    lint_finding_count: int
    ai_comment_count: int
    kept_comment_count: int
    dropped_duplicate_count: int
    dedupe_drop_rate: float


class ReviewResponse(BaseModel):
    """Structured PR/diff review response."""

    status: str = "ok"
    tenant_id: str
    repo: str | None = None
    files_reviewed: list[str]
    lint_findings: list[dict[str, Any]]
    sast_findings: list[dict[str, Any]]
    reachable_symbols: list[dict[str, Any]]
    comments: list[ReviewComment]
    dropped_duplicates: list[ReviewComment]
    summary: ReviewSummary


def _normalize_severity(raw: Any) -> Severity:
    val = str(raw or "MEDIUM").strip().upper()
    if val in _VALID_SEVERITIES:
        return cast(Severity, val)
    return "MEDIUM"


def _coerce_review_comment(
    item: dict[str, Any], *, default_source: CommentSource = "ai"
) -> ReviewComment | None:
    """Validate and normalize a raw comment dict into a :class:`ReviewComment`."""
    path = str(item.get("path") or item.get("file") or "").strip()
    message = str(item.get("message") or "").strip()
    if not path or not message:
        return None
    try:
        line = max(1, int(item.get("line") or 1))
    except (TypeError, ValueError):
        return None
    try:
        end_line = max(line, int(item.get("end_line") or line))
    except (TypeError, ValueError):
        end_line = line
    category = str(item.get("category") or "maintainability").strip().lower()
    source_raw = str(item.get("source") or default_source).strip().lower()
    source: CommentSource = (
        cast(CommentSource, source_raw)
        if source_raw in ("ai", "linter", "sast", "rule")
        else default_source
    )
    return ReviewComment(
        path=path,
        line=line,
        end_line=end_line,
        severity=_normalize_severity(item.get("severity")),
        category=category or "maintainability",
        rule_id=str(item["rule_id"]).strip() if item.get("rule_id") else None,
        tool=str(item["tool"]).strip() if item.get("tool") else None,
        message=message,
        suggestion=str(item["suggestion"]).strip() if item.get("suggestion") else None,
        source=source,
        evidence=list(item.get("evidence") or []),
    )


def _collect_deterministic_findings(
    files: Sequence[str],
    *,
    lint_sarif: dict[str, Any] | None,
    run_server_lint: bool,
    validated_root: str | None,
    tenant_id: str,
    persist_lint_findings: bool,
    neo4j_client: Any,
    qdrant_client: Any,
) -> list[dict[str, Any]]:
    """Collect normalized lint findings from uploaded SARIF and/or gated server lint."""
    findings: list[dict[str, Any]] = []
    if lint_sarif is not None:
        findings.extend(parse_lint_sarif(lint_sarif, root=validated_root))

    if run_server_lint and validated_root and files:
        from backend.config import get_config

        cfg = get_config()
        if cfg.lint_findings_enabled:
            findings.extend(
                collect_lint_findings(
                    files,
                    root=validated_root,
                    timeout=cfg.lint_timeout_sec,
                    safe_mode=True,
                )
            )

    if persist_lint_findings and findings and neo4j_client is not None:
        parsed = parse_sarif_payload(build_sarif_payload(findings))
        write_sarif_findings(
            neo4j_client,
            parsed,
            tenant_id=tenant_id,
            qdrant_client=qdrant_client,
        )
    return findings


def _default_ai_reviewer(
    diff: str,
    files: list[str],
    reachable_symbols: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Invoke the configured OpenAI-compatible LLM for structured JSON review comments."""
    if not diff.strip():
        return []
    from backend.config import get_config

    cfg = get_config()
    if not cfg.llm_api_key and not cfg.llm_base_url:
        return []

    try:
        from openai import OpenAI

        client = OpenAI(**cfg.get_llm_client_args())
        prompt = (
            "Return a JSON object {\"comments\": [...]} with code review comments "
            "for the diff below. Each comment must have: path, line (int), "
            "end_line (int), severity (HIGH|MEDIUM|LOW|INFO), category "
            "(one of: security, architecture, bug, performance, maintainability, "
            "type-error, unused-import, unused-variable, syntax-error), "
            "rule_id (optional), tool (optional), message, suggestion (optional).\n\n"
            f"Files: {json.dumps(files)}\n"
            f"Reachable symbols: {json.dumps(reachable_symbols[:20])}\n\n"
            f"Diff:\n{diff[:_DIFF_PREVIEW_CHARS]}"
        )
        response = client.chat.completions.create(
            model=cfg.llm_model,
            messages=[
                {
                    "role": "system",
                    "content": "You are a strict code reviewer. Output valid JSON only.",
                },
                {"role": "user", "content": prompt},
            ],
            response_format={"type": "json_object"},
            temperature=0.0,
        )
        raw_content = response.choices[0].message.content or "{}"
        parsed = json.loads(raw_content)
        comments = parsed.get("comments") if isinstance(parsed, dict) else []
        return [c for c in (comments or []) if isinstance(c, dict)]
    except Exception as exc:
        logger.warning("Structured AI review failed: %s", exc)
        sentry_sdk.capture_exception(exc)
        return []


def run_structured_review(
    payload: ReviewRequest,
    *,
    touched_files: list[str],
    tenant_id: str = "default",
    validated_root: str | None = None,
    neo4j_client: Any = None,
    qdrant_client: Any = None,
    ai_reviewer: AiReviewer | None = None,
) -> ReviewResponse:
    """Execute structured PR/diff review and dedupe AI comments against lint claims."""
    audit = audit_diff_files(
        touched_files,
        diff=payload.diff,
        tenant_id=tenant_id,
        repo=payload.repo,
        client=neo4j_client,
    )
    reachable_symbols = list(audit.get("reachable_symbols") or [])
    sast_findings = list(audit.get("findings") or [])

    lint_findings = _collect_deterministic_findings(
        touched_files,
        lint_sarif=payload.lint_sarif,
        run_server_lint=payload.run_server_lint,
        validated_root=validated_root,
        tenant_id=tenant_id,
        persist_lint_findings=payload.persist_lint_findings,
        neo4j_client=neo4j_client,
        qdrant_client=qdrant_client,
    )

    raw_ai_comments: list[dict[str, Any]] = []
    if payload.include_ai_review:
        reviewer = ai_reviewer or _default_ai_reviewer
        raw_ai_comments = reviewer(payload.diff, touched_files, reachable_symbols)

    normalized_ai: list[dict[str, Any]] = []
    for raw in raw_ai_comments:
        coerced = _coerce_review_comment(raw, default_source="ai")
        if coerced is not None:
            normalized_ai.append(coerced.model_dump())

    kept_dicts, dropped_dicts = dedupe_review_comments(normalized_ai, lint_findings)
    kept_comments = [ReviewComment(**c) for c in kept_dicts]
    dropped_comments = [ReviewComment(**c) for c in dropped_dicts]

    ai_count = len(normalized_ai)
    dropped_count = len(dropped_comments)
    drop_rate = round(dropped_count / ai_count, 4) if ai_count else 0.0

    return ReviewResponse(
        tenant_id=tenant_id,
        repo=payload.repo,
        files_reviewed=list(touched_files),
        lint_findings=lint_findings,
        sast_findings=sast_findings,
        reachable_symbols=reachable_symbols,
        comments=kept_comments,
        dropped_duplicates=dropped_comments,
        summary=ReviewSummary(
            files_count=len(touched_files),
            reachable_symbol_count=len(reachable_symbols),
            sast_finding_count=len(sast_findings),
            lint_finding_count=len(lint_findings),
            ai_comment_count=ai_count,
            kept_comment_count=len(kept_comments),
            dropped_duplicate_count=dropped_count,
            dedupe_drop_rate=drop_rate,
        ),
    )


__all__ = [
    "ReviewComment",
    "ReviewRequest",
    "ReviewResponse",
    "ReviewSummary",
    "run_structured_review",
]
