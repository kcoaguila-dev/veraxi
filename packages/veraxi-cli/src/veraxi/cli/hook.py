import os
import stat
import subprocess
import sys

HOOK_MARKER_START = "# >>> veraxi hook >>>"
HOOK_MARKER_END = "# <<< veraxi hook <<<"

HOOK_PRE_COMMIT = f"""{HOOK_MARKER_START}
# Veraxi pre-commit hook: audit staged git diff against knowledge base
if command -v vx >/dev/null 2>&1; then
    vx review --staged
elif command -v veraxi >/dev/null 2>&1; then
    veraxi review --staged
fi
{HOOK_MARKER_END}
"""

HOOK_POST_COMMIT = f"""{HOOK_MARKER_START}
# Veraxi post-commit hook: autonomously learn architectural lessons from commit
if command -v vx >/dev/null 2>&1; then
    vx learn --auto
elif command -v veraxi >/dev/null 2>&1; then
    veraxi learn --auto
fi
{HOOK_MARKER_END}
"""

HOOK_SCRIPT = HOOK_PRE_COMMIT


def _find_git_dir() -> str | None:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--git-dir"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return os.path.abspath(out)
    except Exception:
        curr = os.getcwd()
        while curr != os.path.dirname(curr):
            git_path = os.path.join(curr, ".git")
            if os.path.isdir(git_path):
                return git_path
            curr = os.path.dirname(curr)
        return None


def _manage_single_hook(
    hooks_dir: str, hook_name: str, hook_script: str, action: str
) -> None:
    green = "\033[32m"
    bold = "\033[1m"
    reset = "\033[0m"

    hook_path = os.path.join(hooks_dir, hook_name)
    if action == "install":
        content = ""
        if os.path.exists(hook_path):
            with open(hook_path, "r", encoding="utf-8") as f:
                content = f.read()

        if HOOK_MARKER_START in content:
            print(
                f"{bold}Veraxi {hook_name} hook is already installed at {hook_path}{reset}"
            )
            return

        if not content:
            new_content = f"#!/bin/sh\n\n{hook_script}"
        else:
            new_content = content.rstrip() + f"\n\n{hook_script}"

        with open(hook_path, "w", encoding="utf-8") as f:
            f.write(new_content)

        st = os.stat(hook_path)
        os.chmod(hook_path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        print(
            f"{bold}{green}✓ Successfully installed Veraxi {hook_name} hook{reset} at {hook_path}"
        )

    elif action == "uninstall":
        if not os.path.exists(hook_path):
            print(f"No {hook_name} hook found at {hook_path}")
            return

        with open(hook_path, "r", encoding="utf-8") as f:
            content = f.read()

        if HOOK_MARKER_START not in content:
            print(f"No Veraxi hook found in {hook_path}")
            return

        start_idx = content.find(HOOK_MARKER_START)
        end_idx = content.find(HOOK_MARKER_END) + len(HOOK_MARKER_END)
        cleaned = (content[:start_idx] + content[end_idx:]).strip()

        if not cleaned or cleaned == "#!/bin/sh":
            os.remove(hook_path)
            print(f"{bold}{green}✓ Successfully removed {hook_path}{reset}")
        else:
            with open(hook_path, "w", encoding="utf-8") as f:
                f.write(cleaned + "\n")
            print(
                f"{bold}{green}✓ Successfully removed Veraxi hook from {hook_path}{reset}"
            )


def run_hook(action: str = "install", hook_type: str = "pre-commit") -> None:
    """
    Manages Git hooks (pre-commit review, post-commit auto-learning).
    """
    git_dir = _find_git_dir()
    if not git_dir:
        print(
            "Error: Not a git repository (or any of the parent directories).",
            file=sys.stderr,
        )
        sys.exit(1)

    hooks_dir = os.path.join(git_dir, "hooks")
    os.makedirs(hooks_dir, exist_ok=True)

    hook_type = (hook_type or "pre-commit").strip().lower()

    if hook_type in ("pre-commit", "all"):
        _manage_single_hook(hooks_dir, "pre-commit", HOOK_PRE_COMMIT, action)
    if hook_type in ("post-commit", "all"):
        _manage_single_hook(hooks_dir, "post-commit", HOOK_POST_COMMIT, action)
