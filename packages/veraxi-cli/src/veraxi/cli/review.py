import json
import shutil
import subprocess
import sys
from veraxi.cli.query import run_query
from veraxi.cli.rules import _get_active_rules, audit_diff_against_rules
from veraxi.cli.utils import resolve_project_scope


def _extract_diff_files(diff_text: str) -> list[str]:
    """Extract repo-relative changed file paths from unified git diff headers."""
    files: list[str] = []
    seen: set[str] = set()
    for line in (diff_text or "").splitlines():
        if not line.startswith("+++ "):
            continue
        raw = line[4:].strip()
        if raw == "/dev/null":
            continue
        if raw.startswith("b/"):
            raw = raw[2:]
        if raw and raw not in seen:
            seen.add(raw)
            files.append(raw)
    return files


def _collect_local_ruff_sarif(files: list[str]) -> dict | None:
    """Run local ``ruff check --output-format sarif`` on changed Python files."""
    py_files = [f for f in files if f.endswith(".py")]
    if not py_files or not shutil.which("ruff"):
        return None
    try:
        proc = subprocess.run(
            ["ruff", "check", "--output-format", "sarif", "--no-cache", *py_files],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if proc.returncode not in (0, 1):
        return None
    try:
        payload = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def _run_structured_review(
    diff_text: str,
    *,
    project: str | None,
    tenant_id: str,
    endpoint: str,
    key: str | None,
    with_lint: bool,
    as_json: bool,
) -> dict:
    """Post diff + optional local SARIF to ``POST /api/v1/code/review``."""
    from veraxi.cli.http_client import api_request

    files = _extract_diff_files(diff_text)
    lint_sarif = _collect_local_ruff_sarif(files) if with_lint else None
    body: dict = {
        "diff": diff_text,
        "files": files,
        "repo": project,
    }
    if lint_sarif is not None:
        body["lint_sarif"] = lint_sarif

    data = api_request(
        "POST",
        "/api/v1/code/review",
        body=body,
        endpoint=endpoint,
        key=key,
        tenant=tenant_id,
        timeout=60,
    )
    if as_json:
        print(json.dumps(data, indent=2))
        return data

    summary = data.get("summary") or {}
    comments = data.get("comments") or []
    dropped = data.get("dropped_duplicates") or []
    print(
        f"Structured Review: {summary.get('files_count', len(files))} file(s), "
        f"{summary.get('lint_finding_count', 0)} lint finding(s), "
        f"{len(comments)} AI comment(s) kept, "
        f"{len(dropped)} duplicate(s) dropped "
        f"(drop_rate={summary.get('dedupe_drop_rate', 0.0):.2%})"
    )
    for item in comments:
        sev = item.get("severity", "MEDIUM")
        cat = item.get("category", "review")
        path = item.get("path", "")
        line = item.get("line", 0)
        msg = item.get("message", "")
        print(f"  [{sev} {cat}] {path}:{line} — {msg}")
    return data


def run_review(
    staged: bool = False,
    commit_hash: str | None = None,
    limit: int = 10,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me/sse",
    key: str | None = None,
    enforce_rules: bool = False,
    project: str | None = None,
    strict: bool = False,
    as_json: bool = False,
    structured: bool = False,
    with_lint: bool = False,
):
    """
    1-Command Git Diff Auditor & CI Rule Enforcer.
    Extracts git changes, audits against active architectural invariants,
    or runs them through the Veraxi briefing engine.
    """
    try:
        if commit_hash:
            cmd = ["git", "show", commit_hash]
        elif staged:
            cmd = ["git", "diff", "--cached"]
        else:
            res = subprocess.run(["git", "diff"], capture_output=True, text=True, check=True)
            if res.stdout.strip():
                cmd = ["git", "diff"]
            else:
                cmd = ["git", "diff", "HEAD~1"]

        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        diff_text = result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Error running git command: {e}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("Git is not installed or not in PATH.", file=sys.stderr)
        sys.exit(1)

    if not diff_text:
        print("No git diff detected to review.")
        sys.exit(0)

    # If --structured or --with-lint is requested:
    if structured or with_lint:
        _run_structured_review(
            diff_text,
            project=project,
            tenant_id=tenant_id,
            endpoint=endpoint,
            key=key,
            with_lint=with_lint,
            as_json=as_json,
        )
        return

    # If --enforce-rules or --strict rule gate is requested:
    if enforce_rules or strict:
        project_scope = resolve_project_scope(project)
        active_rules = _get_active_rules(project_scope, tenant_id=tenant_id)
        violations = audit_diff_against_rules(diff_text, active_rules)

        if as_json:
            print(json.dumps({
                "project": project_scope,
                "passed": len(violations) == 0,
                "violations_count": len(violations),
                "violations": violations,
            }, indent=2))
            sys.exit(0 if len(violations) == 0 else 1)

        bold = "\033[1m"
        cyan = "\033[36m"
        green = "\033[32m"
        red = "\033[31m"
        reset = "\033[0m"

        print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
        print(f"{bold}{cyan}║            Veraxi CI/CD Architectural Invariant Gate               ║{reset}")
        print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")
        print(f"\n  Project Scope: {bold}{project_scope}{reset}")
        print(f"  Rules Evaluated: {bold}{len(active_rules)}{reset}\n")

        if not violations:
            print(f"  {green}✓ Architectural Compliance PASSED{reset}")
            print("  Zero invariant violations detected across current git changes.\n")
            sys.exit(0)

        print(f"  {red}❌ FAILED: Found {len(violations)} Architectural Invariant Violation(s):{reset}\n")
        for idx, v in enumerate(violations, 1):
            print(f"  {red}[VIOLATION #{idx} - {v['type'].upper()}]{reset}")
            print(f"    • {bold}Rule #{v['rule_id']}:{reset} \"{v['rule_name']}\" [{v['tag']}]")
            print(f"    • {bold}File:{reset}    {v['file']}")
            print(f"    • {bold}Line:{reset}    `{v['line']}`")
            print(f"    • {bold}Issue:{reset}   {v['reason']}")
            print(f"    • {bold}Fix:{reset}     {cyan}{v['remediation']}{reset}\n")

        sys.exit(1)

    # Prepare prompt for briefing engine review
    prompt = f"""
Perform an Architectural & Security Code Review on the following git diff.
Identify breaking changes, regression points, and architectural drift based on the codebase knowledge graph.

Git Diff:
```diff
{diff_text}
```
"""
    print(f"Submitting diff for review (length: {len(diff_text)} chars)...")
    run_query(
        query=prompt.strip(),
        as_json=as_json,
        tenant_id=tenant_id,
        limit=limit,
        endpoint=endpoint,
        key=key,
    )
