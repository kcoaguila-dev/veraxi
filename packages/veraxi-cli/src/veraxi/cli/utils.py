import datetime
import json
import os
import subprocess
import sys


def get_utc_now(formatted: bool = False) -> str:
    """
    Returns the current UTC timestamp in ISO 8601 or human-readable format.
    """
    now = datetime.datetime.now(datetime.timezone.utc)
    if formatted:
        return now.strftime("%Y-%m-%d %H:%M:%S UTC")
    return now.isoformat()


def copy_to_clipboard(text: str) -> bool:
    """
    Copies text to the system clipboard across Android Termux, macOS, Linux, and Windows.
    Returns True if successfully written to clipboard.
    """
    if not text:
        return False

    # 1. Android Termux (termux-api)
    if "TERMUX_VERSION" in os.environ or "com.termux" in os.environ.get("PREFIX", ""):
        try:
            p = subprocess.Popen(["termux-clipboard-set"], stdin=subprocess.PIPE)
            p.communicate(input=text.encode("utf-8"))
            return p.returncode == 0
        except Exception:
            pass

    # 2. macOS (pbcopy)
    if sys.platform == "darwin":
        try:
            p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
            p.communicate(input=text.encode("utf-8"))
            return p.returncode == 0
        except Exception:
            pass

    # 3. Linux / Wayland (wl-copy)
    try:
        p = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE)
        p.communicate(input=text.encode("utf-8"))
        return p.returncode == 0
    except Exception:
        pass

    # 4. Linux / X11 (xclip)
    try:
        p = subprocess.Popen(
            ["xclip", "-selection", "clipboard"], stdin=subprocess.PIPE
        )
        p.communicate(input=text.encode("utf-8"))
        return p.returncode == 0
    except Exception:
        pass

    # 5. Windows (clip)
    if sys.platform == "win32":
        try:
            p = subprocess.Popen(["clip"], stdin=subprocess.PIPE)
            p.communicate(input=text.encode("utf-8"))
            return p.returncode == 0
        except Exception:
            pass

    return False


def resolve_project_scope(explicit_project: str | None = None) -> str:
    """
    Auto-detects the current project namespace from .veraxi/config.json or Git repository root.
    Falls back to current directory basename.
    """
    if explicit_project and explicit_project.strip():
        return explicit_project.strip()

    curr = os.getcwd()
    while curr != os.path.dirname(curr):
        cfg_file = os.path.join(curr, ".veraxi", "config.json")
        if os.path.isfile(cfg_file):
            try:
                with open(cfg_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if "project" in data and data["project"]:
                        return str(data["project"]).strip()
            except Exception:
                pass
        curr = os.path.dirname(curr)

    try:
        toplevel = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return os.path.basename(toplevel)
    except Exception:
        pass

    return os.path.basename(os.getcwd())


def render_progress_bar(used: int, total: int, width: int = 10) -> str:
    """
    Renders an ASCII/Unicode progress bar.
    """
    ratio = min(1.0, max(0.0, used / max(1, total)))
    filled = int(round(ratio * width))
    return "█" * filled + "░" * (width - filled)
