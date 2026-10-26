import subprocess
import sys
from veraxi.cli.query import run_query


def run_review(
    staged: bool = False,
    commit_hash: str | None = None,
    limit: int = 10,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me/sse",
    key: str | None = None,
):
    """
    1-Command Git Diff Auditor
    Extracts git changes and runs them through the Veraxi briefing engine.
    """
    try:
        if commit_hash:
            cmd = ["git", "show", commit_hash]
        elif staged:
            cmd = ["git", "diff", "--cached"]
        else:
            # Check unstaged first
            res = subprocess.run(["git", "diff"], capture_output=True, text=True, check=True)
            if res.stdout.strip():
                cmd = ["git", "diff"]
            else:
                # Fallback to HEAD~1
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

    # Prepare prompt for review
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
        as_json=False,
        tenant_id=tenant_id,
        limit=limit,
        endpoint=endpoint,
        key=key,
    )
