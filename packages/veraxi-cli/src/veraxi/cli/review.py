import json
import subprocess
import sys
from veraxi.cli.query import run_query
from veraxi.cli.rules import _get_active_rules, audit_diff_against_rules
from veraxi.cli.utils import resolve_project_scope


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
