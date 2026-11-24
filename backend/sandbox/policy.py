"""Autonomy policy for sandbox tool calls.

``classify_command`` decides whether a shell command is read-only and
``requires_approval`` combines that with the tenant's ``autonomy_mode``:

- ``ask_all``: every exec / write needs approval.
- ``auto_read_test``: read-only commands (incl. test runners) run
  automatically; writes, installs, and pushes need approval.
- ``auto_workspace_writes``: read-only commands, test runners,
  workspace file writes (``sandbox_write_file`` and file-mutating
  shell commands such as ``mkdir``/``cp``/``sed -i``/output
  redirection), and ``git add`` / ``git commit`` inside the workspace
  run automatically. Anything that reaches outside the workspace or
  changes shared state still needs approval: package installs
  (``pip``/``npm install``/...), network fetches (``curl``/``wget``),
  system commands (``apt``/``sudo``/``kill``/``chmod``/``chown``),
  ``ssh``/``scp``, and every other mutating ``git`` subcommand
  (``checkout``, ``merge``, ``reset``, ``pull``, ``clone``, ...).
- ``autonomous``: everything runs inside the isolated sandbox, except
  ``git push``, which always needs explicit approval in every mode.

``git push`` requires approval in EVERY mode, including
``auto_workspace_writes`` and ``autonomous``.

Plan mode (``execution_mode="plan"``) is orthogonal to autonomy:
:func:`plan_mode_block` returns a structured deny payload for any
mutating operation while planning, and ``None`` when the operation
may proceed (read-only work is always allowed in plan mode).
"""

import logging
import os
import re
import shlex
from pathlib import Path

logger = logging.getLogger(__name__)

READ_ONLY = "read_only"
MUTATING = "mutating"

_READ_ONLY_COMMANDS = {
    "ls", "pwd", "cat", "head", "tail", "rg", "grep", "find", "wc",
    "which", "echo", "printf", "env", "uname", "whoami", "id", "stat",
    "file", "tree", "du", "df", "pytest", "true", "false", "test",
}
_READ_ONLY_PHRASES = (
    "git status", "git diff", "git log", "git show", "git branch",
    "git rev-parse", "git ls-files", "flutter test", "flutter analyze",
    "dart analyze", "python -m pytest", "python3 -m pytest",
    "npm test", "npx tsc --noEmit".lower(),
)
_MUTATING_TOKENS = {
    "rm", "mv", "cp", "mkdir", "touch", "chmod", "chown", "ln",
    "pip", "pip3", "npm", "npx", "yarn", "pnpm", "apt", "apt-get",
    "curl", "wget", "ssh", "scp", "sudo", "kill", "tee", "sed",
    "flutter", "dart", "python", "python3", "node", "make",
}
_GIT_MUTATING = {
    "push", "commit", "add", "checkout", "switch", "merge", "rebase",
    "reset", "clean", "stash", "pull", "clone", "init", "rm", "mv",
    "restore", "apply", "cherry-pick", "tag", "fetch",
}


def _segments(command: str) -> list[str]:
    return [
        s.strip()
        for s in re.split(r"&&|\|\||;|\||\n", command or "")
        if s.strip()
    ]


def _has_shell_expansion(command: str) -> bool:
    """True when the command can smuggle execution past segment checks.

    Command substitution (``$(...)`` / backticks) executes even inside
    double quotes, so it counts everywhere except single quotes.
    Process substitution (``<(`` / ``>(``) and bare newlines only act
    as shell syntax outside any quotes. Any hit fails closed: the
    segment classifier cannot see inside an expansion.
    """
    in_single = False
    in_double = False
    escaped = False
    prev = ""
    for ch in command or "":
        if escaped:
            escaped = False
            prev = ch
            continue
        if ch == "\\" and not in_single:
            escaped = True
            prev = ch
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif not in_single:
            if ch == "`" or (ch == "(" and prev == "$"):
                return True
            if not in_double and (ch == "\n" or (prev in "<>" and ch == "(")):
                return True
        prev = ch
    return False


# `git branch` forms that only list or query refs. Anything else
# (create / delete / rename / copy / force) mutates refs.
_GIT_BRANCH_READ_ONLY_FLAGS = {
    "--list", "-l", "-a", "--all", "-r", "--remotes", "-v", "-vv",
    "--show-current", "--contains", "--merged", "--no-merged",
}
_GIT_BRANCH_VALUE_FLAGS = {"--contains", "--merged", "--no-merged"}


def _git_branch_is_read_only(args: list[str]) -> bool:
    """Argument-aware check for ``git branch`` (never phrase-matched)."""
    i = 0
    while i < len(args):
        token = args[i]
        if token in _GIT_BRANCH_VALUE_FLAGS:
            i += 2  # flag plus its commit-ish value
            continue
        if any(token.startswith(f + "=") for f in _GIT_BRANCH_VALUE_FLAGS):
            i += 1
            continue
        if token not in _GIT_BRANCH_READ_ONLY_FLAGS:
            return False
        i += 1
    return True


def _segment_is_read_only(segment: str) -> bool:
    lowered = segment.lower()
    if lowered.startswith("git branch"):
        # `git branch` is argument-sensitive (listing vs -D/create);
        # never approve it via the phrase list.
        try:
            branch_tokens = shlex.split(segment)
        except ValueError:
            return False
        if len(branch_tokens) >= 2 and branch_tokens[1] == "branch":
            return _git_branch_is_read_only(branch_tokens[2:])
        return False
    if any(lowered.startswith(p) or lowered == p for p in _READ_ONLY_PHRASES):
        return True
    try:
        tokens = shlex.split(segment)
    except ValueError:
        return False
    if not tokens:
        return True
    head = tokens[0].rsplit("/", 1)[-1]
    if head == "git":
        if len(tokens) < 2:
            return True
        return tokens[1] not in _GIT_MUTATING and tokens[1] in {
            "status", "diff", "log", "show", "branch", "rev-parse",
            "ls-files", "describe", "remote", "config",
        }
    if head in ("pytest",):
        return True
    if head in _MUTATING_TOKENS:
        # flutter/dart/python handled by phrase check above; bare
        # invocations are treated as mutating (they can write files).
        return False
    return head in _READ_ONLY_COMMANDS


def is_git_push(command: str) -> bool:
    """True when any segment of ``command`` is a ``git push``."""
    for segment in _segments(command or ""):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            continue
        heads = [t.rsplit("/", 1)[-1] for t in tokens]
        if len(heads) >= 2 and heads[0] == "git" and heads[1] == "push":
            return True
        if "git push" in segment:
            return True
    return False


def classify_command(command: str) -> str:
    """Classify a shell command as ``read_only`` or ``mutating``."""
    cmd = (command or "").strip()
    if not cmd:
        return READ_ONLY
    if _has_shell_expansion(cmd):
        return MUTATING
    if ">" in cmd or ">>" in cmd:
        return MUTATING
    if is_git_push(cmd):
        return MUTATING
    for segment in _segments(cmd):
        if not _segment_is_read_only(segment):
            return MUTATING
    return READ_ONLY


_INSTALL_NETWORK_SYSTEM_HEADS = {
    "pip", "pip3", "apt", "apt-get", "curl", "wget", "sudo", "ssh",
    "scp", "kill", "chmod", "chown",
}
_PACKAGE_MANAGER_HEADS = {"npm", "npx", "yarn", "pnpm"}
# File-mutating shell heads whose effects are path-bounded: every
# path operand is checked against the workspace before auto-approval.
_WORKSPACE_WRITE_HEADS = {
    "rm", "mv", "cp", "mkdir", "touch", "ln", "tee", "sed",
}
# Toolchain heads auto-approved only for test/lint subcommands.
_FLUTTER_AUTO_SUBCOMMANDS = {"test", "analyze"}
_DART_AUTO_SUBCOMMANDS = {"analyze", "test", "format"}
# `python -m <module>` entry points that only test or lint.
_PYTHON_AUTO_MODULES = {"pytest", "ruff"}
# The only mutating git subcommands auto-approved in the workspace:
# they stage/commit work that stays local until a (separately gated)
# push.
_GIT_WORKSPACE_OK = {"add", "commit"}


def _segment_head(segment: str) -> tuple[str, list[str]]:
    try:
        tokens = shlex.split(segment)
    except ValueError:
        return "", []
    if not tokens:
        return "", []
    return tokens[0].rsplit("/", 1)[-1], tokens


def _path_within_workspace(raw: str, workspace_root: str | None) -> bool:
    """Whether one path operand provably stays inside the workspace.

    Dynamic paths (env vars, ``~``, globs) cannot be proven safe and
    fail closed. With a known ``workspace_root`` the path is resolved
    against it; without one (the dispatch layer has no root — the
    sandbox session is only created after the approval check) the
    sandbox's implicit working directory is the root, so only plain
    relative paths that never climb out with ``..`` qualify and every
    absolute path requires approval.
    """
    if not raw or any(c in raw for c in "$~*?["):
        return False
    if workspace_root:
        root = Path(workspace_root).resolve()
        candidate = Path(raw)
        resolved = (
            candidate.resolve()
            if candidate.is_absolute()
            else (root / candidate).resolve()
        )
        return resolved == root or root in resolved.parents
    if os.path.isabs(raw):
        return False
    normalized = os.path.normpath(raw)
    return normalized != ".." and not normalized.startswith("../")


def _all_paths_within_workspace(
    paths: list[str], workspace_root: str | None
) -> bool:
    """True when every path operand stays inside the workspace."""
    return all(_path_within_workspace(p, workspace_root) for p in paths)


_REDIRECTION_TARGET_RE = re.compile(r"(?:\d+|&)?>>?\s*([^\s;|&]+)")


def _redirection_targets(command: str) -> list[str]:
    """Output-redirection targets (``>``, ``>>``, ``1>``, ``2>``, ``&>``)."""
    return _REDIRECTION_TARGET_RE.findall(command or "")


def _auto_workspace_segment_requires_approval(
    segment: str, workspace_root: str | None = None
) -> bool:
    """One command segment under the ``auto_workspace_writes`` rule."""
    if _segment_is_read_only(segment):
        return False
    head, tokens = _segment_head(segment)
    if head == "git":
        subcommand = tokens[1] if len(tokens) >= 2 else ""
        return subcommand not in _GIT_WORKSPACE_OK
    if head in _INSTALL_NETWORK_SYSTEM_HEADS:
        return True
    if head in _PACKAGE_MANAGER_HEADS:
        # Test/typecheck phrases were already cleared as read-only
        # above; any other package-manager invocation can install.
        return True
    if head in ("python", "python3"):
        # Only explicit test/lint module entry points; `-c`, scripts,
        # and `-m pip` are arbitrary code / installs and need approval.
        if len(tokens) >= 3 and tokens[1] == "-m":
            module = tokens[2]
            if module not in _PYTHON_AUTO_MODULES:
                return True
            if module == "pytest":
                return False
            return not (len(tokens) >= 4 and tokens[3] == "check")
        return True
    if head in ("node", "make"):
        # Bare interpreters / build drivers run arbitrary code whose
        # effects are not path-bounded; never auto-approved.
        return True
    if head == "flutter":
        subcommand = tokens[1] if len(tokens) >= 2 else ""
        return subcommand not in _FLUTTER_AUTO_SUBCOMMANDS
    if head == "dart":
        subcommand = tokens[1] if len(tokens) >= 2 else ""
        return subcommand not in _DART_AUTO_SUBCOMMANDS
    if head in _WORKSPACE_WRITE_HEADS:
        operands = [t for t in tokens[1:] if not t.startswith("-")]
        return not _all_paths_within_workspace(operands, workspace_root)
    # Unknown mutating segments fail closed to approval.
    return True


def _auto_workspace_requires_approval(
    command: str | None,
    *,
    is_write: bool,
    workspace_root: str | None = None,
) -> bool:
    if command is None:
        # sandbox_write_file writes inside the tenant workspace.
        return not is_write
    cmd = command.strip()
    if not cmd:
        return False
    if _has_shell_expansion(cmd):
        return True
    # Every redirection target must stay inside the workspace.
    if not _all_paths_within_workspace(
        _redirection_targets(cmd), workspace_root
    ):
        return True
    if ">" in cmd:
        # Output redirection is a workspace write — unless a segment
        # independently needs approval (install/network/system/git).
        segments = [s.replace(">", " ") for s in _segments(cmd)]
        return any(
            _auto_workspace_segment_requires_approval(s, workspace_root)
            for s in segments
        )
    return any(
        _auto_workspace_segment_requires_approval(s, workspace_root)
        for s in _segments(cmd)
    )


def requires_approval(
    autonomy_mode: str | None,
    command: str | None = None,
    *,
    is_write: bool = False,
    workspace_root: str | None = None,
) -> bool:
    """Whether a sandbox operation needs user approval first."""
    mode = (autonomy_mode or "auto_read_test").strip().lower()
    if command and is_git_push(command):
        return True
    if mode == "ask_all":
        return True
    if mode == "autonomous":
        return False
    if mode == "auto_workspace_writes":
        return _auto_workspace_requires_approval(
            command, is_write=is_write, workspace_root=workspace_root
        )
    # auto_read_test (and any unknown mode fails closed to it)
    if is_write:
        return True
    if command is None:
        return False
    return classify_command(command) == MUTATING


_PLAN_BLOCKED_TOOLS = {"sandbox_write_file"}


def plan_mode_block(
    execution_mode: str | None,
    *,
    tool_name: str | None = None,
    command: str | None = None,
    is_write: bool = False,
) -> dict | None:
    """Structured deny payload when plan mode forbids an operation.

    Returns ``{"error": "plan_mode_blocked", ...}`` for a mutating
    operation under ``execution_mode="plan"`` — a ``sandbox_write_file``
    call, any explicit write, or a ``sandbox_exec`` whose command
    classifies as mutating. Returns ``None`` when the operation may
    proceed: act mode, read-only commands, and read tools are never
    blocked. Dispatch layers must check this BEFORE executing, so a
    mutating tool invoked directly (bypassing the offered tool list)
    is still refused.
    """
    if (execution_mode or "act").strip().lower() != "plan":
        return None
    blocked = is_write or tool_name in _PLAN_BLOCKED_TOOLS
    if not blocked and tool_name == "sandbox_exec" and command is not None:
        blocked = classify_command(command) == MUTATING
    if not blocked and tool_name is None and command is not None:
        blocked = classify_command(command) == MUTATING
    if not blocked:
        return None
    return {
        "error": "plan_mode_blocked",
        "execution_mode": "plan",
        "tool_name": tool_name,
        "message": (
            "Plan mode is active: mutating tools and commands are "
            "blocked. Inspect and propose a plan instead of executing."
        ),
    }


def is_plan_blocked(
    execution_mode: str | None,
    *,
    tool_name: str | None = None,
    command: str | None = None,
    is_write: bool = False,
) -> bool:
    """Boolean form of :func:`plan_mode_block`."""
    return (
        plan_mode_block(
            execution_mode, tool_name=tool_name, command=command, is_write=is_write
        )
        is not None
    )
