import json
import re
import subprocess
import sys
from veraxi.cli.memory import run_remember
from veraxi.cli.rules import run_rules_sync
from veraxi.cli.utils import resolve_project_scope


SKIP_PREFIXES = (
    "chore", "docs", "doc", "ci", "style", "test", "tests",
    "bump", "wip", "merge", "formatting", "typo", "release",
)

TAG_KEYWORDS = {
    "auth": ("auth", "jwt", "token", "session", "oauth", "password", "login"),
    "db": ("db", "database", "sql", "postgres", "neo4j", "qdrant", "model", "migration", "query"),
    "api": ("api", "endpoint", "route", "http", "controller", "graphql", "rest"),
    "ui": ("ui", "css", "component", "view", "react", "flutter", "frontend"),
    "cache": ("cache", "redis", "memcached"),
    "perf": ("perf", "performance", "latency", "optimize"),
    "security": ("security", "permission", "cors", "csrf", "secret"),
}


def _infer_tag(scope: str | None, text: str, files: list[str]) -> str:
    if scope:
        clean_scope = scope.lower().strip()
        for tag, kws in TAG_KEYWORDS.items():
            if clean_scope == tag or clean_scope in kws:
                return tag
        return clean_scope

    combined = (text + " " + " ".join(files)).lower()
    for tag, kws in TAG_KEYWORDS.items():
        if any(kw in combined for kw in kws):
            return tag

    return "architecture"


def _clean_invariant_text(raw_text: str) -> str:
    text = raw_text.strip()
    # Normalize common prefix forms
    text = re.sub(r"^(prevent|fix|avoid|ensure|require|enforce)\s+", lambda m: m.group(1).capitalize() + " ", text, flags=re.IGNORECASE)
    if text and not text[0].isupper():
        text = text[0].upper() + text[1:]
    if text and not text.endswith((".", "!", "?")):
        text += "."
    return text


def extract_commit_lesson(commit: str = "HEAD") -> dict | None:
    """
    Extracts candidate architectural rule and metadata from git commit history.
    """
    try:
        raw = subprocess.check_output(
            ["git", "log", "-1", "--format=%H%x00%s%x00%b", commit],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        return None

    if not raw:
        return None

    parts = raw.split("\x00")
    commit_hash = parts[0]
    subject = parts[1].strip() if len(parts) > 1 else ""
    body = parts[2].strip() if len(parts) > 2 else ""

    # Check for trivial / chore commit
    lower_subj = subject.lower()
    for pfx in SKIP_PREFIXES:
        if lower_subj.startswith(f"{pfx}:") or lower_subj.startswith(f"{pfx}(") or lower_subj == pfx:
            return None

    # Get modified files
    files = []
    try:
        file_lines = subprocess.check_output(
            ["git", "diff-tree", "--no-commit-id", "--name-only", "-r", commit_hash],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip().splitlines()
        files = [f.strip() for f in file_lines if f.strip()]
    except Exception:
        pass

    # Match conventional commit
    match = re.match(r"^(?P<type>fix|feat|refactor|perf|security)(\((?P<scope>[^)]+)\))?:\s*(?P<msg>.+)", subject, re.IGNORECASE)
    if match:
        scope = match.group("scope")
        msg = match.group("msg").strip()
        tag = _infer_tag(scope, msg, files)
        rule_text = _clean_invariant_text(msg)
    else:
        tag = _infer_tag(None, subject, files)
        rule_text = _clean_invariant_text(subject)

    if len(rule_text.split()) < 3:
        return None

    return {
        "commit": commit_hash,
        "short_hash": commit_hash[:8],
        "subject": subject,
        "body": body,
        "rule": rule_text,
        "tag": tag,
        "files_count": len(files),
    }


def run_learn(
    commit: str = "HEAD",
    auto: bool = False,
    yes: bool = False,
    sync: bool = False,
    project: str | None = None,
    tenant_id: str = "default",
    as_json: bool = False,
) -> None:
    """
    Analyzes git commit/diff to distill architectural rules and persists them to memory bank.
    """
    project_scope = resolve_project_scope(project)
    lesson = extract_commit_lesson(commit=commit)

    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    yellow = "\033[33m"
    reset = "\033[0m"

    if not lesson:
        if as_json:
            print(json.dumps({"project": project_scope, "learned": False, "reason": "No architectural invariant detected."}))
            return
        if not auto:
            print(f"\n{yellow}No architectural invariant detected in commit {commit}.{reset}")
            print("Commit may be trivial (chore, docs, formatting) or non-prescriptive.\n")
        return

    if as_json and not auto and not yes:
        print(json.dumps({
            "project": project_scope,
            "learned": True,
            "candidate": lesson,
        }, indent=2))
        return

    confirmed_rule = lesson["rule"]
    confirmed_tag = lesson["tag"]

    if not auto and not yes and sys.stdin.isatty():
        print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
        print(f"{bold}{cyan}║                 Veraxi Autonomous Memory Learner                   ║{reset}")
        print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")
        print(f"\n  Commit: {bold}{lesson['short_hash']}{reset} ({lesson['subject']})")
        print(f"  Project Scope: {bold}{project_scope}{reset}")
        print(f"\n  {bold}Candidate Rule:{reset} \"{confirmed_rule}\"")
        print(f"  {bold}Inferred Tag:{reset}   [{confirmed_tag}]")

        try:
            prompt = f"\n  Save to Veraxi architectural memory bank? [{bold}Y{reset}/n/edit]: "
            choice = input(prompt).strip().lower()
            if choice == "n":
                print("  Skipped.")
                return
            elif choice == "edit":
                edited = input("  Enter updated rule: ").strip()
                if edited:
                    confirmed_rule = _clean_invariant_text(edited)
        except (KeyboardInterrupt, EOFError):
            print("\n  Aborted.")
            return

    # Persist the rule
    run_remember(
        name=confirmed_rule,
        tag=confirmed_tag,
        project=project_scope,
        tenant_id=tenant_id,
        as_json=as_json,
    )

    if not as_json:
        print(f"  {green}✓ Successfully captured architectural invariant into {bold}{project_scope}{reset} memory bank.")

    if sync:
        if not as_json:
            print(f"  {cyan}↻ Syncing updated rules to AI editor configs (CLAUDE.md, .cursorrules)...{reset}")
        run_rules_sync(project=project_scope, tenant_id=tenant_id, as_json=as_json)
