"""Autonomy policy for sandbox tool calls.

``classify_command`` decides whether a shell command is read-only and
``requires_approval`` combines that with the tenant's ``autonomy_mode``:

- ``ask_all``: every exec / write needs approval.
- ``auto_read_test``: read-only commands (incl. test runners) run
  automatically; writes, installs, and pushes need approval.
- ``autonomous``: everything runs inside the isolated sandbox, except
  ``git push``, which always needs explicit approval in every mode.
"""

import logging
import re
import shlex

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
    return [s.strip() for s in re.split(r"&&|\|\||;|\|", command or "") if s.strip()]


def _segment_is_read_only(segment: str) -> bool:
    lowered = segment.lower()
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
    if ">" in cmd or ">>" in cmd:
        return MUTATING
    if is_git_push(cmd):
        return MUTATING
    for segment in _segments(cmd):
        if not _segment_is_read_only(segment):
            return MUTATING
    return READ_ONLY


def requires_approval(
    autonomy_mode: str | None,
    command: str | None = None,
    *,
    is_write: bool = False,
) -> bool:
    """Whether a sandbox operation needs user approval first."""
    mode = (autonomy_mode or "auto_read_test").strip().lower()
    if command and is_git_push(command):
        return True
    if mode == "ask_all":
        return True
    if mode == "autonomous":
        return False
    # auto_read_test (and any unknown mode fails closed to it)
    if is_write:
        return True
    if command is None:
        return False
    return classify_command(command) == MUTATING
