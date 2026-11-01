"""Zero-trust sandboxed Python code execution tool.

Runs user or agent-provided Python code inside an isolated subprocess
with resource limits (POSIX rlimit) and runtime audit hooks (sys.addaudithook)
to prevent socket networking, subprocess spawning, sensitive file inspection,
and arbitrary filesystem write operations.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from typing import Any

# Harness executed inside the child process.
# Keeps the harness self-contained so that no external packages are needed.
_SANDBOX_HARNESS = r"""
import os
import sys

sandbox_dir = sys.argv[1]
code_file = sys.argv[2]

try:
    import resource

    # Set CPU time limit to 5 seconds
    resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
    # Virtual memory limit: 512 MB
    max_mem = 512 * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (max_mem, max_mem))
    # File write size limit: 10 MB
    max_fsize = 10 * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_FSIZE, (max_fsize, max_fsize))
except Exception:
    # Non-POSIX or restricted systems
    pass


def _audit_guard(event: str, args: tuple) -> None:
    # 1. Block all network socket creation and interaction
    if event.startswith("socket."):
        raise PermissionError(f"Network access is forbidden in sandbox: {event}")

    # 2. Block child process spawning / shell execution
    if event.startswith("subprocess.") or event in (
        "os.system",
        "os.posix_spawn",
        "os.spawn",
        "os.exec",
        "os.fork",
        "os.forkpty",
    ):
        raise PermissionError(f"Process execution is forbidden in sandbox: {event}")

    # 3. Block ctypes / dynamic library loading
    if event.startswith("ctypes."):
        raise PermissionError(f"Direct native memory access is forbidden in sandbox: {event}")

    # 4. Block directory listing outside sandbox_dir and standard library prefixes
    if event in ("os.listdir", "os.scandir"):
        dir_arg = args[0] if args else "."
        if not isinstance(dir_arg, int):
            norm_dir = os.path.realpath(str(dir_arg))
            norm_sandbox = os.path.realpath(sandbox_dir)
            allowed_dir_prefixes = (
                norm_sandbox,
                os.path.realpath(sys.prefix),
                os.path.realpath(sys.base_prefix),
                "/usr",
                "/lib",
                "/lib64",
            )
            if not any(norm_dir.startswith(prefix) for prefix in allowed_dir_prefixes):
                raise PermissionError(f"Directory listing outside sandbox forbidden: {dir_arg}")

    # 5. Filter filesystem reads/writes
    if event == "open":
        path = args[0]
        mode = args[1] if len(args) > 1 else ""
        flags = args[2] if len(args) > 2 else 0

        if isinstance(path, (int, bytes)):
            return

        path_str = str(path)
        norm = os.path.realpath(path_str)

        # Block reading sensitive host files, credentials, and environmental secrets
        blocked_patterns = (
            ".env",
            ".ssh",
            "/etc/shadow",
            "/etc/passwd",
            "/etc/sudoers",
            "/root",
            "id_rsa",
            "id_ed25519",
        )
        for bp in blocked_patterns:
            if bp in norm:
                raise PermissionError(f"Read access to sensitive resource forbidden: {path_str}")

        # Block write operations outside the allocated sandbox directory
        is_write = (
            any(m in (mode or "") for m in ("w", "a", "x", "+"))
            or bool(flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT))
        )
        norm_sandbox = os.path.realpath(sandbox_dir)
        if is_write:
            if not norm.startswith(norm_sandbox):
                raise PermissionError(f"Write access outside sandbox forbidden: {path_str}")
        else:
            # Strict read whitelist: only allow sandbox_dir and standard Python/OS runtime libraries
            allowed_read_prefixes = (
                norm_sandbox,
                os.path.realpath(sys.prefix),
                os.path.realpath(sys.base_prefix),
                "/usr",
                "/lib",
                "/lib64",
                "/etc/ld.so",
                "/etc/localtime",
                "/dev/null",
                "/dev/urandom",
                "/proc/self",
            )
            if not any(norm.startswith(prefix) for prefix in allowed_read_prefixes):
                raise PermissionError(f"Read access outside sandbox forbidden: {path_str}")


sys.addaudithook(_audit_guard)

with open(code_file, "r", encoding="utf-8") as f:
    user_code = f.read()

exec_globals = {
    "__name__": "__main__",
    "__doc__": None,
    "__builtins__": __builtins__,
}

compiled = compile(user_code, filename="<sandbox>", mode="exec")
exec(compiled, exec_globals)
"""


def execute_python_code(code: str, timeout: int = 10) -> dict[str, Any]:
    """Executes Python code in an isolated, zero-trust sandbox.

    Enforces:
    - Zero network sockets
    - Zero subprocess spawning
    - Sandboxed local file I/O
    - Memory & CPU resource limits
    - Stripped environment without host API keys

    Returns stdout, stderr, and exit_code.
    """
    temp_dir = tempfile.mkdtemp(prefix="veraxi_sandbox_")
    code_path = os.path.join(temp_dir, "script.py")
    harness_path = os.path.join(temp_dir, "harness.py")

    try:
        with open(code_path, "w", encoding="utf-8") as f:
            f.write(code)

        with open(harness_path, "w", encoding="utf-8") as f:
            f.write(_SANDBOX_HARNESS)

        # Sanitized minimal environment (no host API keys or tokens)
        clean_env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "HOME": temp_dir,
            "PYTHONPATH": "",
        }

        # Spawn isolated interpreter
        result = subprocess.run(  # noqa: PLW1510
            [
                sys.executable,
                "-I",  # Isolated mode: ignore PYTHONPATH, user site, env
                "-B",  # Do not write bytecode .pyc
                harness_path,
                temp_dir,
                code_path,
            ],
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=temp_dir,
            env=clean_env,
        )
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": result.returncode,
        }
    except subprocess.TimeoutExpired as e:
        stdout_txt = (
            e.stdout
            if isinstance(e.stdout, str)
            else (e.stdout.decode("utf-8") if e.stdout else "")
        )
        stderr_txt = (
            e.stderr
            if isinstance(e.stderr, str)
            else (e.stderr.decode("utf-8") if e.stderr else "")
        )
        return {
            "stdout": stdout_txt,
            "stderr": f"Execution timed out after {timeout} seconds.\n{stderr_txt}",
            "exit_code": 124,
        }
    except Exception as e:
        return {
            "stdout": "",
            "stderr": f"Failed to execute code in sandbox: {e!s}",
            "exit_code": 1,
        }
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)
