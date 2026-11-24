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
``tool_dispatch.get_tools`` removes ``sandbox_exec`` and
``sandbox_write_file`` from the offered tool list, and
:func:`plan_mode_block` enforces a structured deny payload at dispatch
time for any mutating operation while planning.
"""

import logging
import posixpath
import shlex

logger = logging.getLogger(__name__)

READ_ONLY = "read_only"
MUTATING = "mutating"

_READ_ONLY_COMMANDS = {
    "ls", "pwd", "cat", "head", "tail", "rg", "grep", "wc",
    "which", "echo", "printf", "env", "uname", "whoami", "id", "stat",
    "file", "tree", "du", "df", "pytest", "true", "false", "test",
}
_READ_ONLY_PHRASES = (
    "flutter test", "flutter analyze",
    "dart analyze", "python -m pytest", "python3 -m pytest",
    "npm test", "npx tsc --noemit",
)
_MUTATING_TOKENS = {
    "rm", "mv", "cp", "mkdir", "touch", "chmod", "chown", "ln",
    "pip", "pip3", "npm", "npx", "yarn", "pnpm", "apt", "apt-get",
    "curl", "wget", "ssh", "scp", "sudo", "kill", "tee", "sed",
    "flutter", "dart", "python", "python3", "node", "make", "find",
}
_GIT_READ_ONLY = {
    "status", "diff", "log", "show", "branch", "rev-parse",
    "ls-files", "describe",
}
_GIT_GLOBAL_VALUE_FLAGS = {
    "-C", "-c", "--git-dir", "--work-tree", "--namespace",
    "--super-prefix", "--exec-path", "--list-cmds",
}
_GIT_GLOBAL_BOOL_FLAGS = {
    "-p", "--paginate", "-P", "--no-pager", "--bare",
    "--no-replace-objects", "--literal-pathspecs", "--glob-pathspecs",
    "--noglob-pathspecs", "--icase-pathspecs", "--no-optional-locks",
}
_FIND_MUTATING_FLAGS = {
    "-delete", "-exec", "-execdir", "-ok", "-okdir",
    "-fprint", "-fprint0", "-fprintf", "-fls",
}


def _segments(command: str) -> list[str]:
    """Split a shell command on unquoted command separators.

    Splits on ``&&``, ``||``, ``;``, ``|``, ``&``, and ``\\n`` outside
    single/double quotes so ``ls & rm -rf /`` is never treated as a
    single ``ls`` segment while quoted ``echo "a & b"`` stays intact.
    """
    text = command or ""
    parts: list[str] = []
    buf: list[str] = []
    in_single = False
    in_double = False
    escaped = False
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if escaped:
            buf.append(ch)
            escaped = False
            i += 1
            continue
        if ch == "\\" and not in_single:
            buf.append(ch)
            escaped = True
            i += 1
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
            buf.append(ch)
            i += 1
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            buf.append(ch)
            i += 1
            continue
        if not in_single and not in_double:
            if ch in (";", "\n"):
                seg = "".join(buf).strip()
                if seg:
                    parts.append(seg)
                buf.clear()
                i += 1
                continue
            if ch in ("&", "|"):
                seg = "".join(buf).strip()
                if seg:
                    parts.append(seg)
                buf.clear()
                if i + 1 < n and text[i + 1] == ch:
                    i += 2
                else:
                    i += 1
                continue
        buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        parts.append(tail)
    return parts


def _has_shell_expansion(command: str) -> bool:
    """True when the command can smuggle execution past segment checks.

    Command substitution (``$(...)`` / backticks) executes even inside
    double quotes, so it counts everywhere except single quotes.
    Process substitution (``<(`` / ``>(``), bare newlines, and unclosed
    quotes fail closed: the segment classifier cannot see inside them.
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
    return in_single or in_double or escaped


def _git_subcommand_and_args(tokens: list[str]) -> tuple[str, list[str]]:
    """Resolve the git subcommand past global options like ``-C dir``."""
    i = 1
    while i < len(tokens):
        tok = tokens[i]
        if tok == "--":
            i += 1
            break
        if tok in _GIT_GLOBAL_VALUE_FLAGS:
            i += 2
            continue
        if any(tok.startswith(f + "=") for f in _GIT_GLOBAL_VALUE_FLAGS):
            i += 1
            continue
        if tok in _GIT_GLOBAL_BOOL_FLAGS:
            i += 1
            continue
        if tok.startswith("-"):
            # Unknown global flag: cannot safely assume next token is subcommand.
            return "", tokens[i:]
        return tok, tokens[i + 1 :]
    return "", []


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
        subcommand, rest = _git_subcommand_and_args(tokens)
        if not subcommand or subcommand not in _GIT_READ_ONLY:
            return False
        if subcommand == "branch":
            return _git_branch_is_read_only(rest)
        return not any(a == "--output" or a.startswith("--output=") for a in rest)
    if head == "find":
        return not any(t in _FIND_MUTATING_FLAGS for t in tokens[1:])
    if head == "pytest":
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
            if "git" in segment and "push" in segment:
                return True
            continue
        if not tokens:
            continue
        head = tokens[0].rsplit("/", 1)[-1]
        if head == "git":
            subcommand, _ = _git_subcommand_and_args(tokens)
            if subcommand == "push":
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
    if _has_unquoted_redirection(cmd):
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

    Uses pure POSIX path normalization (never touching the host API
    server's filesystem, since commands execute inside a remote
    sandbox). Dynamic paths (env vars, ``~``, globs, NULs) fail closed.
    """
    if not raw or "\x00" in raw or any(c in raw for c in "$~*?["):
        return False
    if workspace_root:
        root = posixpath.normpath(workspace_root)
        if not root.startswith("/"):
            return False
        joined = (
            posixpath.normpath(raw)
            if raw.startswith("/")
            else posixpath.normpath(posixpath.join(root, raw))
        )
        root_prefix = "/" if root == "/" else root.rstrip("/") + "/"
        return joined == root or joined.startswith(root_prefix)
    if raw.startswith("/"):
        return False
    normalized = posixpath.normpath(raw)
    return normalized != ".." and not normalized.startswith("../")


def _all_paths_within_workspace(
    paths: list[str], workspace_root: str | None
) -> bool:
    """True when every path operand stays inside the workspace."""
    return all(_path_within_workspace(p, workspace_root) for p in paths)


def _has_unquoted_redirection(command: str) -> bool:
    """True when ``command`` contains an unquoted ``>`` or ``>>``."""
    in_single = False
    in_double = False
    escaped = False
    for ch in command:
        if escaped:
            escaped = False
            continue
        if ch == "\\" and not in_single:
            escaped = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == ">" and not in_single and not in_double:
            return True
    return False


def _extract_redirections(command: str) -> tuple[list[str], str, bool]:
    """Extract unquoted output-redirection targets in linear time.

    Returns ``(targets, stripped_command, valid)``. ``targets`` are
    unquoted via ``shlex.split`` so quoted escapes like
    ``> "../outside.txt"`` are still resolved and checked.
    """
    targets: list[str] = []
    out: list[str] = []
    in_single = False
    in_double = False
    escaped = False
    i = 0
    n = len(command)
    while i < n:
        ch = command[i]
        if escaped:
            out.append(ch)
            escaped = False
            i += 1
            continue
        if ch == "\\" and not in_single:
            out.append(ch)
            escaped = True
            i += 1
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
            out.append(ch)
            i += 1
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            out.append(ch)
            i += 1
            continue
        if ch == ">" and not in_single and not in_double:
            # Strip optional leading fd digit (`1>`, `2>`) or `&` (`&>`)
            while out and (out[-1].isdigit() or out[-1] == "&"):
                # Only strip fd/ampersand if at token start
                if len(out) >= 2 and not out[-2].isspace() and out[-2] not in (";", "|", "&"):
                    break
                out.pop()
                if out and out[-1] == "&":
                    break
            out.append(" ")
            i += 1
            if i < n and command[i] == ">":
                i += 1
            while i < n and command[i].isspace():
                i += 1
            # Scan one shell word as the redirection target.
            start = i
            t_single = False
            t_double = False
            t_esc = False
            while i < n:
                tc = command[i]
                if t_esc:
                    t_esc = False
                    i += 1
                    continue
                if tc == "\\" and not t_single:
                    t_esc = True
                    i += 1
                    continue
                if tc == "'" and not t_double:
                    t_single = not t_single
                elif tc == '"' and not t_single:
                    t_double = not t_double
                elif not t_single and not t_double and (tc.isspace() or tc in (";", "|", "&")):
                    break
                i += 1
            raw_word = command[start:i]
            if not raw_word:
                return [], command, False
            try:
                parsed = shlex.split(raw_word)
            except ValueError:
                return [], command, False
            if len(parsed) != 1:
                return [], command, False
            targets.append(parsed[0])
            continue
        out.append(ch)
        i += 1
    return targets, "".join(out), True


def _workspace_write_requires_approval(
    head: str, tokens: list[str], workspace_root: str | None
) -> bool:
    if head == "ln" and any(t == "-s" or t == "--symbolic" for t in tokens[1:]):
        return True
    if head == "sed" and any(
        t in ("-f", "--file") or t.startswith("--file=") for t in tokens[1:]
    ):
        return True
    operands: list[str] = []
    i = 1
    while i < len(tokens):
        tok = tokens[i]
        if tok == "--":
            operands.extend(tokens[i + 1 :])
            break
        if tok in ("-t", "--target-directory") and i + 1 < len(tokens):
            operands.append(tokens[i + 1])
            i += 2
            continue
        if tok.startswith("--target-directory="):
            operands.append(tok.split("=", 1)[1])
            i += 1
            continue
        if not tok.startswith("-"):
            operands.append(tok)
        i += 1
    if head == "sed" and operands:
        # First non-flag arg for sed is the script, remaining are file paths.
        operands = operands[1:]
    return not _all_paths_within_workspace(operands, workspace_root)


def _auto_workspace_segment_requires_approval(
    segment: str, workspace_root: str | None = None
) -> bool:
    """One command segment under the ``auto_workspace_writes`` rule."""
    if _segment_is_read_only(segment):
        return False
    head, tokens = _segment_head(segment)
    if head == "git":
        subcommand, _ = _git_subcommand_and_args(tokens)
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
        return _workspace_write_requires_approval(head, tokens, workspace_root)
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
    targets, stripped_cmd, valid = _extract_redirections(cmd)
    if not valid or not _all_paths_within_workspace(targets, workspace_root):
        return True
    return any(
        _auto_workspace_segment_requires_approval(s, workspace_root)
        for s in _segments(stripped_cmd)
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
