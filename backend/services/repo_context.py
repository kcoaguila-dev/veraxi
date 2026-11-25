"""Workspace context builder for Veraxi Code Mode (Tier 0 Front Door).

Produces a lean, deterministic ``<workspace_context>`` system block
containing the active repository identity, top-level file listing,
selected knowledge sources, and capped root agent instructions
(``AGENTS.md`` / ``CLAUDE.md``). Full files like ``README.md`` are
intentionally NOT dumped into every prompt — the agent fetches them on
demand via ``code_read_file``.
"""

from __future__ import annotations

import logging
from typing import Any

from backend.services.repo_files import (
    RepoFileError,
    list_repo_entries,
    read_repo_file,
    verify_tenant_repo_access,
)

logger = logging.getLogger(__name__)

_MAX_ROOT_ENTRIES = 40
_MAX_INSTRUCTION_CHARS = 1200
_INSTRUCTION_CANDIDATES = (
    "AGENTS.md",
    "CLAUDE.md",
    ".github/copilot-instructions.md",
)


def resolve_active_repo_key(tool_settings: dict[str, Any] | None) -> str | None:
    """Return the active ``repo_key`` from ``tool_settings``, if any."""
    if not isinstance(tool_settings, dict):
        return None
    direct = tool_settings.get("repo_key")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()
    scope = tool_settings.get("source_scope")
    if isinstance(scope, dict):
        repo_keys = scope.get("repo_keys")
        if isinstance(repo_keys, (list, tuple)):
            for item in repo_keys:
                if isinstance(item, str) and item.strip():
                    return item.strip()
    return None


def _format_entries(entries: list[dict[str, Any]]) -> str:
    if not entries:
        return "(unavailable)"
    items = []
    for entry in entries[:_MAX_ROOT_ENTRIES]:
        name = str(entry.get("name") or entry.get("path") or "")
        if not name:
            continue
        suffix = "/" if entry.get("type") == "dir" else ""
        items.append(f"{name}{suffix}")
    return ", ".join(items) if items else "(empty)"


async def _load_instruction_file(
    tenant_id: str,
    repo_key: str,
    entries: list[dict[str, Any]],
    *,
    neo4j_client: Any = None,
    supabase: Any = None,
    redis_client: Any = None,
    config: Any = None,
) -> tuple[str, str] | None:
    """Load the first present root agent-instruction file, capped."""
    root_names = {str(e.get("name") or "") for e in entries}
    for candidate in _INSTRUCTION_CANDIDATES:
        top = candidate.split("/", 1)[0]
        if entries and top not in root_names:
            continue
        try:
            res = await read_repo_file(
                tenant_id,
                repo_key,
                candidate,
                max_chars=_MAX_INSTRUCTION_CHARS,
                neo4j_client=neo4j_client,
                supabase=supabase,
                redis_client=redis_client,
                config=config,
            )
            text = (res.get("content") or "").strip()
            if text:
                return candidate, text
        except RepoFileError:
            continue
        except Exception as exc:
            logger.debug("Instruction probe skipped for %s/%s: %s", repo_key, candidate, exc)
    return None


def _selected_sources_summary(tool_settings: dict[str, Any]) -> list[str]:
    scope = tool_settings.get("source_scope")
    if not isinstance(scope, dict):
        return []
    lines: list[str] = []
    repo_keys = [
        str(k) for k in (scope.get("repo_keys") or []) if isinstance(k, str) and k.strip()
    ]
    if len(repo_keys) > 1:
        lines.append(f"Selected repositories: {', '.join(repo_keys)}")
    doc_ids = [
        str(d) for d in (scope.get("doc_ids") or scope.get("source_ids") or []) if d
    ]
    if doc_ids:
        lines.append(f"Selected Knowledge Hub documents: {len(doc_ids)} active")
    return lines


async def build_workspace_context_prompt(
    tenant_id: str | None,
    tool_settings: dict[str, Any] | None,
    *,
    neo4j_client: Any = None,
    supabase: Any = None,
    redis_client: Any = None,
    config: Any = None,
) -> str | None:
    """Build the ``<workspace_context>`` system note for Code Mode, or None."""
    if not isinstance(tool_settings, dict):
        return None
    workspace_mode = str(tool_settings.get("workspace_mode") or "chat").lower()
    repo_key = resolve_active_repo_key(tool_settings)
    if workspace_mode != "code" and not repo_key:
        return None

    execution_mode = str(tool_settings.get("execution_mode") or "act").lower()
    if not repo_key:
        extra = _selected_sources_summary(tool_settings)
        extra_block = ("\n" + "\n".join(extra)) if extra else ""
        return (
            "<workspace_context>\n"
            f"Workspace Mode: code (execution_mode: {execution_mode})\n"
            "Active Repository: none selected (scratchpad){extra_block}\n"
            "</workspace_context>"
        ).format(extra_block=extra_block)

    effective_tenant = tenant_id or "default"
    access = await verify_tenant_repo_access(
        effective_tenant, repo_key, neo4j_client=neo4j_client, supabase=supabase
    )
    meta = (access or {}).get("meta") or {}
    gh_repo = (access or {}).get("gh_repo") or {}

    branch = (
        tool_settings.get("branch")
        or gh_repo.get("default_branch")
        or "default"
    )
    commit = str(meta.get("source_commit") or gh_repo.get("last_indexed_sha") or "")
    commit_str = commit[:12] if commit else "unknown"

    entries: list[dict[str, Any]] = []
    if access is not None:
        try:
            listed = await list_repo_entries(
                effective_tenant,
                repo_key,
                path="",
                limit=_MAX_ROOT_ENTRIES,
                neo4j_client=neo4j_client,
                supabase=supabase,
                redis_client=redis_client,
                config=config,
            )
            entries = listed.get("entries") or []
        except Exception as exc:
            logger.debug("Root listing skipped for %s: %s", repo_key, exc)

    instruction = None
    if access is not None:
        instruction = await _load_instruction_file(
            effective_tenant,
            repo_key,
            entries,
            neo4j_client=neo4j_client,
            supabase=supabase,
            redis_client=redis_client,
            config=config,
        )

    lines = [
        "<workspace_context>",
        f"Workspace Mode: code (execution_mode: {execution_mode})",
        f"Active Repository: {repo_key}",
        f"Branch: {branch} | Indexed Commit: {commit_str}",
        *_selected_sources_summary(tool_settings),
        f"Top-level entries: {_format_entries(entries)}",
        "",
        "WORKSPACE RULES:",
        f"- The user is actively working inside repository `{repo_key}`.",
        "- NEVER ask the user which repository they are referring to when their question involves files, README, docs, code, or architecture in this workspace.",
        f"- All `code_*` and `github_*` tools automatically default to `{repo_key}` when `repo` is omitted.",
        "- Use `code_read_file(path=...)` to read files (such as `README.md`, configs, or source code) and `code_list_files(path=..., pattern=...)` to browse directories before answering.",
    ]
    if instruction is not None:
        inst_path, inst_text = instruction
        lines.extend(
            [
                "",
                f"<project_instructions path=\"{inst_path}\">",
                inst_text,
                "</project_instructions>",
            ]
        )
    lines.append("</workspace_context>")
    return "\n".join(lines)
