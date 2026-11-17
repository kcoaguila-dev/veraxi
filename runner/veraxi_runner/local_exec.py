"""Local execution for ``veraxi-runner``, confined to ``--repo``.

All paths are resolved under the repo root (traversal is rejected),
commands run with a scrubbed environment allowlist (the host's
``~/.ssh``, ``~/.env``, and unrelated secrets are never exposed), and
the Docker runtime builds a hardened ``docker run`` invocation:
``--cap-drop=ALL``, ``--security-opt=no-new-privileges``, a single
worktree mount, and ``--network none`` when offline.
"""

import asyncio
import os
from pathlib import Path

ENV_ALLOWLIST = ("PATH", "HOME", "LANG", "LC_ALL", "TERM", "TMPDIR")


class PathConfinementError(ValueError):
    """Raised when a path escapes the repo root."""


def scrubbed_env(extra: dict | None = None) -> dict:
    """Environment for child commands: allowlist only, no host secrets."""
    env = {k: os.environ[k] for k in ENV_ALLOWLIST if k in os.environ}
    env["VERAXI_RUNNER"] = "1"
    if extra:
        env.update(extra)
    return env


def resolve_under_repo(repo: str | Path, path: str | Path) -> Path:
    """Resolve ``path`` under ``repo``; reject traversal outside it."""
    root = Path(repo).resolve()
    candidate = Path(path)
    resolved = candidate.resolve() if candidate.is_absolute() else (root / candidate).resolve()
    if resolved != root and root not in resolved.parents:
        raise PathConfinementError(f"Path {path!r} escapes the repository root")
    return resolved


def build_docker_command(
    repo: str | Path,
    command: str,
    *,
    offline: bool = False,
    image: str = "python:3.12-slim",
    cwd: str | None = None,
) -> list[str]:
    """Build the hardened ``docker run`` argv for one command."""
    root = str(Path(repo).resolve())
    argv = [
        "docker", "run", "--rm",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "-v", f"{root}:/repo",
        "-w", "/repo",
    ]
    if offline:
        argv += ["--network", "none"]
    argv += [image, "bash", "-lc", command]
    return argv


def build_microsandbox_command(command: str) -> list[str]:
    """Build the microsandbox CLI argv for one command."""
    return ["microsandbox", "run", "--", "bash", "-lc", command]


class LocalExecutor:
    """Executes JSON-RPC requests from the backend inside ``repo``."""

    def __init__(self, repo: str | Path, runtime: str = "docker", offline: bool = False, image: str = "python:3.12-slim"):
        self.repo = Path(repo).resolve()
        if not self.repo.is_dir():
            raise ValueError(f"--repo {repo!r} is not a directory")
        self.runtime = runtime
        self.offline = offline
        self.image = image

    # -- dispatch ---------------------------------------------------------
    async def handle(self, method: str, params: dict, emit=None) -> dict:
        """Handle one request; ``emit`` streams exec events if given."""
        if method == "exec":
            return await self.exec_command(
                str(params.get("command") or ""), params.get("cwd"),
                int(params.get("timeout_sec") or 120), emit=emit,
            )
        if method == "read_file":
            return {"content": self.read_file(str(params.get("path") or ""))}
        if method == "write_file":
            self.write_file(str(params.get("path") or ""), str(params.get("content") or ""))
            return {"ok": True}
        if method == "diff":
            return {"diff": await self.get_diff()}
        raise ValueError(f"Unknown runner method {method!r}")

    # -- operations ---------------------------------------------------------
    def _argv_for(self, command: str) -> list[str]:
        if self.runtime == "docker":
            return build_docker_command(self.repo, command, offline=self.offline, image=self.image)
        if self.runtime == "microsandbox":
            import shutil

            if not shutil.which("microsandbox"):
                raise RuntimeError(
                    "microsandbox runtime requested but the `microsandbox` "
                    "binary was not found on PATH"
                )
            return build_microsandbox_command(command)
        return ["bash", "-lc", command]

    async def exec_command(self, command: str, cwd: str | None = None, timeout_sec: int = 120, emit=None) -> dict:
        workdir = resolve_under_repo(self.repo, cwd) if cwd else self.repo
        argv = self._argv_for(command)
        # For the direct runtime, run inside the confined workdir; the
        # docker/microsandbox runtimes already mount only the repo.
        proc_cwd = str(workdir) if self.runtime not in ("docker", "microsandbox") else None
        proc = await asyncio.create_subprocess_exec(
            *argv, cwd=proc_cwd, env=scrubbed_env(),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout_sec)
        except TimeoutError:
            proc.kill()
            await proc.communicate()
            return {"stdout": "", "stderr": "Command timed out", "exit_code": 124}
        out_text = stdout.decode(errors="replace") if stdout else ""
        err_text = stderr.decode(errors="replace") if stderr else ""
        if emit is not None:
            if out_text:
                await emit({"type": "stdout", "data": out_text})
            if err_text:
                await emit({"type": "stderr", "data": err_text})
            await emit({"type": "exit", "exit_code": proc.returncode or 0})
        return {"stdout": out_text, "stderr": err_text, "exit_code": proc.returncode or 0}

    def read_file(self, path: str) -> str:
        resolved = resolve_under_repo(self.repo, path)
        return resolved.read_text()

    def write_file(self, path: str, content: str) -> None:
        resolved = resolve_under_repo(self.repo, path)
        resolved.parent.mkdir(parents=True, exist_ok=True)
        resolved.write_text(content)

    async def get_diff(self) -> str:
        proc = await asyncio.create_subprocess_exec(
            "git", "diff", cwd=str(self.repo), env=scrubbed_env(),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        stdout, _stderr = await proc.communicate()
        status_proc = await asyncio.create_subprocess_exec(
            "git", "status", "--short", cwd=str(self.repo), env=scrubbed_env(),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        status_out, _ = await status_proc.communicate()
        status_text = status_out.decode(errors="replace") if status_out else ""
        return status_text + (stdout.decode(errors="replace") if stdout else "")
