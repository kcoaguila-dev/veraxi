"""Git diff / accept / revert / commit helpers for Code Mode (Phase 2).

All git work runs inside a sandbox session through the provider's
``exec_command`` — the same string-command channel ``_gather_exec``
in :mod:`backend.sandbox.manager` collects. Arguments that carry
user input (paths, commit messages) are always ``shlex.quote``-d,
and file paths are additionally passed only after a ``--`` separator
so a path can never be reinterpreted as a git flag.

This module is the single home of the diff parsing: the sandbox
routes (``routes/sandboxes.py``) and the chat stream
(``routes/chat.py``) both call :func:`collect_session_diff` so the
``files_changed`` summary a turn emits is byte-identical to what the
diff endpoint returns for the same session.
"""

import posixpath
import re
import shlex

LANGUAGE_BY_EXTENSION: dict[str, str] = {
    ".py": "python",
    ".dart": "dart",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".js": "javascript",
    ".jsx": "javascript",
    ".mjs": "javascript",
    ".cjs": "javascript",
    ".toml": "toml",
    ".yaml": "yaml",
    ".yml": "yaml",
    ".json": "json",
    ".md": "markdown",
    ".markdown": "markdown",
    ".html": "html",
    ".css": "css",
    ".scss": "scss",
    ".sh": "shell",
    ".bash": "shell",
    ".sql": "sql",
    ".rs": "rust",
    ".go": "go",
    ".java": "java",
    ".kt": "kotlin",
    ".swift": "swift",
    ".c": "c",
    ".h": "c",
    ".cpp": "cpp",
    ".hpp": "cpp",
    ".rb": "ruby",
    ".php": "php",
    ".txt": "text",
    ".xml": "xml",
    ".svg": "xml",
    ".csv": "csv",
    ".ini": "ini",
    ".cfg": "ini",
    ".lock": "text",
}

LANGUAGE_BY_FILENAME: dict[str, str] = {
    "Dockerfile": "dockerfile",
    "Makefile": "makefile",
    ".gitignore": "gitignore",
}

# Untracked previews are capped so a generated file cannot flood the
# diff payload, and untracked file count is capped to bound RPCs.
_UNTRACKED_PREVIEW_LINES = 200
_MAX_UNTRACKED_FILES = 50


class GitError(RuntimeError):
    """A git command inside the sandbox failed."""


class NotGitRepoError(GitError):
    """The sandbox session's working tree is not a git repository."""


class PathValidationError(ValueError):
    """A user-supplied path failed strict repo-relative validation."""


def language_for_path(path: str) -> str:
    """Map a repo-relative path to a language id (fallback: extension)."""
    name = posixpath.basename(path)
    if name in LANGUAGE_BY_FILENAME:
        return LANGUAGE_BY_FILENAME[name]
    ext = posixpath.splitext(name)[1].lower()
    if ext in LANGUAGE_BY_EXTENSION:
        return LANGUAGE_BY_EXTENSION[ext]
    return ext.lstrip(".") or "text"


async def _gather(provider, session_id: str, cmd: str, timeout_sec: int = 60):
    """Collect one provider exec into ``(stdout, stderr, exit_code)``."""
    stdout_parts: list[str] = []
    stderr_parts: list[str] = []
    exit_code: int | None = None
    async for event in provider.exec_command(session_id, cmd, timeout_sec=timeout_sec):
        if event.kind == "stdout":
            stdout_parts.append(event.data)
        elif event.kind == "stderr":
            stderr_parts.append(event.data)
        elif event.kind == "exit":
            exit_code = event.exit_code
    return "".join(stdout_parts), "".join(stderr_parts), exit_code


async def get_repo_root(provider, session_id: str) -> str:
    """Return the repo root inside the session or raise NotGitRepoError."""
    stdout, stderr, exit_code = await _gather(
        provider, session_id, "git rev-parse --show-toplevel"
    )
    root = stdout.strip().splitlines()[0].strip() if stdout.strip() else ""
    if exit_code != 0 or not root:
        raise NotGitRepoError(
            "Sandbox session is not inside a git repository"
            + (f": {stderr.strip()}" if stderr.strip() else "")
        )
    return root


def validate_repo_paths(paths, repo_root: str) -> list[str]:
    """Validate user paths and return repo-relative POSIX paths.

    Strict, fail-closed rules: the list must be non-empty; every path
    must be non-empty, contain no NUL, not look like a flag (leading
    ``-``), contain no ``..`` component, and — when absolute — resolve
    inside ``repo_root``. The repo root itself is not a file and is
    rejected.
    """
    if not paths:
        raise PathValidationError("paths must not be empty")
    root = posixpath.normpath(repo_root)
    validated: list[str] = []
    for raw in paths:
        rel = _validate_one_path(raw, root)
        if rel not in validated:
            validated.append(rel)
    return validated


def _validate_one_path(raw, root: str) -> str:
    if not isinstance(raw, str) or not raw.strip():
        raise PathValidationError("path must not be empty")
    if "\x00" in raw:
        raise PathValidationError("path must not contain NUL bytes")
    candidate = raw.strip()
    if candidate.startswith("-"):
        raise PathValidationError(f"path {raw!r} looks like a flag")
    parts = candidate.split("/")
    if ".." in parts:
        raise PathValidationError(f"path {raw!r} escapes the repository root")
    if posixpath.isabs(candidate):
        normalized = posixpath.normpath(candidate)
        if normalized != root and not normalized.startswith(root + "/"):
            raise PathValidationError(
                f"path {raw!r} is outside the repository root"
            )
        rel = posixpath.relpath(normalized, root)
    else:
        rel = posixpath.normpath(candidate)
    if rel in ("", "."):
        raise PathValidationError("path must name a file inside the repository")
    if ".git" in rel.split("/"):
        # Nothing under .git/ is a reviewable file; accepting or
        # reverting it would let a caller rewrite hooks/config.
        raise PathValidationError("path must not target .git internals")
    if rel.startswith("../") or rel == "..":
        raise PathValidationError(f"path {raw!r} escapes the repository root")
    return rel


def parse_numstat(text: str) -> dict[str, tuple[int, int]]:
    """Parse ``git diff --numstat`` output into path -> (adds, dels)."""
    stats: dict[str, tuple[int, int]] = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 3:
            continue
        try:
            additions = int(fields[0])
            deletions = int(fields[1])
        except ValueError:
            # Binary files report "-"; they contribute no line counts.
            additions, deletions = 0, 0
        path = fields[2] if len(fields) == 3 else "\t".join(fields[2:])
        if " => " in path:  # rename: keep the new path
            path = path.split(" => ", 1)[1].strip().strip("{}")
        stats[path] = (additions, deletions)
    return stats


_HUNK_RE = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def parse_unified_diff(text: str) -> dict[str, dict]:
    """Parse a unified diff into path -> {status, hunks}."""
    files: dict[str, dict] = {}
    current: dict | None = None
    current_hunk: dict | None = None
    for line in text.splitlines():
        if line.startswith("diff --git "):
            current = {"status": "modified", "hunks": []}
            current_hunk = None
            match = re.match(r"^diff --git a/(.*) b/(.*)$", line)
            path = match.group(2) if match else line.split(" b/", 1)[-1]
            files[path] = current
            continue
        if current is None:
            continue
        if line.startswith("new file mode"):
            current["status"] = "added"
            continue
        if line.startswith("deleted file mode"):
            current["status"] = "deleted"
            continue
        if line.startswith("rename from "):
            current["status"] = "renamed"
            continue
        if line.startswith("rename to "):
            current["status"] = "renamed"
            new_path = line[len("rename to "):]
            old_keys = [k for k, v in files.items() if v is current]
            for old_key in old_keys:
                del files[old_key]
            files[new_path] = current
            continue
        hunk_match = _HUNK_RE.match(line)
        if hunk_match:
            current_hunk = {
                "old_start": int(hunk_match.group(1)),
                "new_start": int(hunk_match.group(2)),
                "lines": [line],
            }
            current["hunks"].append(current_hunk)
            continue
        if current_hunk is not None:
            current_hunk["lines"].append(line)
    return files


def _count_preview_additions(hunks: list[dict]) -> int:
    return sum(
        1
        for hunk in hunks
        for line in hunk["lines"]
        if line.startswith("+") and not line.startswith("+++")
    )


def build_diff_summary(
    session_id: str,
    turn_id: str,
    numstat_text: str,
    diff_text: str,
    untracked: list[tuple[str, str]] | None = None,
) -> dict:
    """Assemble the exact Phase 2 diff response shape from raw git output.

    ``untracked`` is a list of ``(path, no-index diff text)`` previews.
    """
    stats = parse_numstat(numstat_text)
    parsed = parse_unified_diff(diff_text)
    files: list[dict] = []
    seen: set[str] = set()
    for path in sorted(set(stats) | set(parsed)):
        seen.add(path)
        additions, deletions = stats.get(path, (0, 0))
        entry = parsed.get(path, {"status": "modified", "hunks": []})
        if path not in stats:
            # Diff-only path (should not happen with --numstat on the
            # same tree, but never fabricate zero counts silently).
            additions = _count_preview_additions(entry["hunks"])
            deletions = sum(
                1
                for hunk in entry["hunks"]
                for line in hunk["lines"]
                if line.startswith("-") and not line.startswith("---")
            )
        files.append(
            {
                "path": path,
                "language": language_for_path(path),
                "status": entry["status"],
                "additions": additions,
                "deletions": deletions,
                "hunks": entry["hunks"],
            }
        )
    for path, preview_text in untracked or []:
        if path in seen:
            continue
        preview = parse_unified_diff(preview_text).get(path)
        if preview is None:
            # Fall back to any single parsed file in the preview.
            parsed_preview = parse_unified_diff(preview_text)
            preview = next(iter(parsed_preview.values()), {"hunks": []})
        hunks = preview["hunks"]
        files.append(
            {
                "path": path,
                "language": language_for_path(path),
                "status": "untracked",
                "additions": _count_preview_additions(hunks),
                "deletions": 0,
                "hunks": hunks,
            }
        )
    files.sort(key=lambda f: f["path"])
    return {
        "session_id": session_id,
        "turn_id": turn_id,
        "total_additions": sum(f["additions"] for f in files),
        "total_deletions": sum(f["deletions"] for f in files),
        "files": files,
    }


async def collect_session_diff(provider, session_id: str, turn_id: str = "") -> dict:
    """Run the read-only git commands and build the diff summary."""
    await get_repo_root(provider, session_id)
    numstat, stderr, exit_code = await _gather(
        provider, session_id, "git -c core.quotepath=false diff HEAD --numstat"
    )
    if exit_code != 0:
        raise NotGitRepoError(
            "git diff failed in sandbox session"
            + (f": {stderr.strip()}" if stderr.strip() else "")
        )
    diff_text, _stderr, exit_code = await _gather(
        provider, session_id, "git -c core.quotepath=false diff HEAD -U3"
    )
    if exit_code != 0:
        raise GitError("git diff failed in sandbox session")
    untracked_text, _stderr, _code = await _gather(
        provider,
        session_id,
        "git -c core.quotepath=false ls-files --others --exclude-standard",
    )
    all_untracked = [ln.strip() for ln in untracked_text.splitlines() if ln.strip()]
    untracked_truncated = len(all_untracked) > _MAX_UNTRACKED_FILES
    untracked: list[tuple[str, str]] = []
    for path in all_untracked[:_MAX_UNTRACKED_FILES]:
        preview, _e, _c = await _gather(
            provider,
            session_id,
            f"git -c core.quotepath=false diff --no-index -U3 -- /dev/null {shlex.quote(path)}",
        )
        preview_lines = preview.splitlines()
        if len(preview_lines) > _UNTRACKED_PREVIEW_LINES:
            preview = "\n".join(
                preview_lines[:_UNTRACKED_PREVIEW_LINES]
                + ["... (preview truncated)"]
            )
        untracked.append((path, preview))
    summary = build_diff_summary(session_id, turn_id, numstat, diff_text, untracked)
    if untracked_truncated:
        summary["untracked_truncated"] = True
    return summary


async def git_add_paths(provider, session_id: str, rel_paths: list[str]) -> None:
    """Stage each validated path (``git add -- <path>`` per file)."""
    for rel in rel_paths:
        _out, stderr, exit_code = await _gather(
            provider, session_id, f"git add -- {shlex.quote(rel)}"
        )
        if exit_code != 0:
            raise GitError(
                f"git add failed for {rel}"
                + (f": {stderr.strip()}" if stderr.strip() else "")
            )


async def git_revert_paths(provider, session_id: str, rel_paths: list[str]) -> None:
    """Revert each validated path to its ``HEAD`` state.

    Files present in ``HEAD`` are restored with
    ``git checkout HEAD -- <path>`` (index AND working tree — a plain
    ``git checkout --`` restores from the index, so a file that was
    already Accepted/staged would silently keep its changes). Files
    absent from ``HEAD`` (newly staged or untracked) are unstaged
    with ``git rm --cached`` and removed from the working tree.
    """
    for rel in rel_paths:
        _out, _err, code = await _gather(
            provider,
            session_id,
            f"git cat-file -e {shlex.quote(f'HEAD:{rel}')}",
        )
        if code == 0:
            _o, stderr, exit_code = await _gather(
                provider, session_id, f"git checkout HEAD -- {shlex.quote(rel)}"
            )
            if exit_code != 0:
                raise GitError(
                    f"git checkout failed for {rel}"
                    + (f": {stderr.strip()}" if stderr.strip() else "")
                )
        else:
            await _gather(
                provider,
                session_id,
                f"git rm -f --cached --ignore-unmatch -- {shlex.quote(rel)}",
            )
            _o, stderr, exit_code = await _gather(
                provider, session_id, f"rm -f -- {shlex.quote(rel)}"
            )
            if exit_code != 0:
                raise GitError(
                    f"failed to remove untracked file {rel}"
                    + (f": {stderr.strip()}" if stderr.strip() else "")
                )


async def git_commit(provider, session_id: str, message: str) -> None:
    """Commit staged files with the user's message. NEVER pushes."""
    _out, stderr, exit_code = await _gather(
        provider, session_id, f"git commit -m {shlex.quote(message)}"
    )
    if exit_code != 0:
        raise GitError(
            "git commit failed"
            + (f": {stderr.strip()}" if stderr.strip() else "")
        )
