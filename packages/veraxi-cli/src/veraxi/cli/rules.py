import json
import os
import re
import sys
from veraxi.cli.cluster import get_cluster_repos
from veraxi.cli.utils import get_utc_now, resolve_project_scope

MANAGED_START = "<!-- VERAXI_MANAGED_START (DO NOT EDIT DIRECTLY) -->"
MANAGED_END = "<!-- VERAXI_MANAGED_END -->"

_resolve_project_scope = resolve_project_scope


def _get_utc_now() -> str:
    return get_utc_now(formatted=True)


def _get_active_rules(project_scope: str, tenant_id: str = "default") -> list[dict]:
    """
    Fetches active rules for the current project, its microservice cluster, and global scope.
    """
    sister_repos = get_cluster_repos(project_scope, tenant_id=tenant_id)
    all_scoped = set(sister_repos)
    all_scoped.add(project_scope)
    all_scoped.add("global")

    rules = []
    # 1. Try Neo4j Knowledge Graph
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        query = """
        MATCH (n:Memory)
        WHERE (n.tenant_id = $tenant_id OR n.tenant_id = 'default')
          AND n.status = 'active'
          AND (n.project IN $repos OR n.project = 'global' OR n.project IS NULL)
        RETURN n.id as id, n.name as name, n.tag as tag, n.type as type, n.project as project
        ORDER BY n.created_at ASC
        """
        rows = neo4j.execute_read(query, {"tenant_id": tenant_id, "repos": list(all_scoped)})
        neo4j.close()
        for r in rows:
            rules.append({
                "id": r.get("id"),
                "name": r.get("name"),
                "tag": r.get("tag", "rule"),
                "type": r.get("type", "rule"),
                "project": r.get("project", project_scope),
            })
    except Exception:
        pass

    # 2. Offline fallback: check local .veraxi/rules.json if present
    if not rules:
        local_file = os.path.join(os.getcwd(), ".veraxi", "rules.json")
        if os.path.isfile(local_file):
            try:
                with open(local_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    for item in data.get("memories", []):
                        if item.get("status") == "active":
                            proj = item.get("project")
                            if proj in all_scoped or proj == "global" or not proj:
                                rules.append(item)
            except Exception:
                pass

    return rules


OPPOSING_DOMAINS = [
    ({"cookie", "cookies"}, {"header", "headers", "bearer"}),
    ({"sync", "synchronous"}, {"async", "asynchronous"}),
    ({"rest", "restful"}, {"graphql", "grpc"}),
    ({"tabs"}, {"spaces"}),
    ({"sql", "relational", "postgres"}, {"nosql", "mongo", "mongodb"}),
    ({"localstorage"}, {"httponly", "cookie", "cookies"}),
    ({"pydantic v1", "pydantic 1"}, {"pydantic v2", "pydantic 2"}),
]

POSITIVE_MARKERS = {"always", "require", "required", "must", "prefer", "use", "enable", "ensure", "adopt"}
NEGATIVE_MARKERS = {"never", "avoid", "deprecate", "deprecated", "forbid", "forbidden", "prohibit", "prohibited", "disable", "disallow", "stop", "dont", "do not", "must not", "cannot"}
STOPWORDS = {"a", "an", "the", "in", "on", "of", "to", "for", "with", "and", "or", "is", "are", "it", "this", "that", "all", "by", "as", "at", "be"}


def detect_rule_conflicts(rules: list[dict]) -> list[dict]:
    """
    Analyzes active rules pairwise for semantic contradictions, opposing directives,
    version discrepancies, and token-wasting redundancies.
    """
    conflicts = []
    n = len(rules)

    for i in range(n):
        for j in range(i + 1, n):
            r1 = rules[i]
            r2 = rules[j]

            t1 = (r1.get("name") or "").lower()
            t2 = (r2.get("name") or "").lower()

            words1 = {re.sub(r"\W+", "", w) for w in t1.split() if len(w) > 2 and w not in STOPWORDS}
            words2 = {re.sub(r"\W+", "", w) for w in t2.split() if len(w) > 2 and w not in STOPWORDS}

            # 1. Opposing Domain Check
            for set_a, set_b in OPPOSING_DOMAINS:
                a_in_1 = any(term in t1 for term in set_a)
                b_in_2 = any(term in t2 for term in set_b)
                b_in_1 = any(term in t1 for term in set_b)
                a_in_2 = any(term in t2 for term in set_a)

                if (a_in_1 and b_in_2) or (b_in_1 and a_in_2):
                    shared_tags = bool(r1.get("tag") and r1.get("tag") == r2.get("tag"))
                    shared_keywords = words1.intersection(words2)
                    if shared_tags or len(shared_keywords) >= 1 or any(k in t1 and k in t2 for k in ("auth", "api", "data", "token", "session", "db", "query", "indent")):
                        conflicts.append({
                            "severity": "CRITICAL",
                            "type": "contradiction",
                            "rule_a": r1,
                            "rule_b": r2,
                            "reason": f"Opposing architectural conventions detected ({', '.join(set_a)} vs {', '.join(set_b)}).",
                            "remediation": f"Resolve either #{r1.get('id')} or #{r2.get('id')} using 'vx memory resolve <id>'.",
                        })
                        break

            # 2. Polarity / Negation Conflict (one says always/use, other says never/avoid on same entity)
            has_pos_1 = any(m in t1 for m in POSITIVE_MARKERS)
            has_neg_1 = any(m in t1 for m in NEGATIVE_MARKERS)
            has_pos_2 = any(m in t2 for m in POSITIVE_MARKERS)
            has_neg_2 = any(m in t2 for m in NEGATIVE_MARKERS)

            is_polarity_clash = (has_pos_1 and has_neg_2) or (has_neg_1 and has_pos_2)
            if is_polarity_clash:
                shared_nouns = words1.intersection(words2) - POSITIVE_MARKERS - NEGATIVE_MARKERS
                if len(shared_nouns) >= 1:
                    conflicts.append({
                        "severity": "CRITICAL",
                        "type": "polarity_clash",
                        "rule_a": r1,
                        "rule_b": r2,
                        "reason": f"Direct polarity clash on target concept(s): {', '.join(shared_nouns)}.",
                        "remediation": "Verify intended convention; retire the deprecated rule via 'vx memory resolve <id>'.",
                    })

            # 3. High Redundancy / Duplicate Check (Jaccard similarity > 0.75)
            if words1 and words2:
                intersection = words1.intersection(words2)
                union = words1.union(words2)
                jaccard = len(intersection) / len(union) if union else 0.0
                if jaccard >= 0.75 and t1 != t2:
                    conflicts.append({
                        "severity": "WARNING",
                        "type": "redundancy",
                        "rule_a": r1,
                        "rule_b": r2,
                        "reason": f"High lexical redundancy ({int(jaccard * 100)}% overlap). Wasting prompt tokens.",
                        "remediation": "Consolidate duplicate rules into a single canonical entry.",
                    })

    return conflicts


def run_rules_lint(
    project: str | None = None,
    tenant_id: str = "default",
    strict: bool = False,
    as_json: bool = False,
) -> None:
    """
    Lints active architectural rules for contradictions, polarity clashes, and bloat.
    """
    project_scope = _resolve_project_scope(project)
    active_rules = _get_active_rules(project_scope, tenant_id=tenant_id)
    conflicts = detect_rule_conflicts(active_rules)

    if as_json:
        print(json.dumps({
            "project": project_scope,
            "total_rules": len(active_rules),
            "conflicts_count": len(conflicts),
            "clean": len(conflicts) == 0,
            "conflicts": conflicts,
        }, indent=2))
        if strict and conflicts:
            sys.exit(1)
        return

    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    yellow = "\033[33m"
    red = "\033[31m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi Architectural Rulebook Linter               ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")

    print(f"\n  Project Scope: {bold}{project_scope}{reset}")
    print(f"  Active Rules Audited: {bold}{len(active_rules)}{reset}\n")

    if not conflicts:
        print(f"  {green}✓ All active rules are coherent.{reset}")
        print("  Zero semantic contradictions or token-wasting redundancies detected.\n")
        return

    critical_count = sum(1 for c in conflicts if c["severity"] == "CRITICAL")
    warning_count = sum(1 for c in conflicts if c["severity"] == "WARNING")

    print(f"  {red if critical_count else yellow}⚠️  Found {len(conflicts)} rule issue(s) ({critical_count} critical, {warning_count} warnings):{reset}\n")

    for idx, c in enumerate(conflicts, 1):
        color = red if c["severity"] == "CRITICAL" else yellow
        print(f"  {color}[{c['severity']} - {c['type'].upper()} #{idx}]{reset}")
        print(f"    • {bold}Rule #{c['rule_a'].get('id')}:{reset} \"{c['rule_a'].get('name')}\" [{c['rule_a'].get('tag', 'rule')}]")
        print(f"    • {bold}Rule #{c['rule_b'].get('id')}:{reset} \"{c['rule_b'].get('name')}\" [{c['rule_b'].get('tag', 'rule')}]")
        print(f"    • {bold}Issue:{reset} {c['reason']}")
        print(f"    • {bold}Fix:{reset} {cyan}{c['remediation']}{reset}\n")

    if strict and critical_count > 0:
        print(f"  {red}Lint failed: {critical_count} critical conflict(s) must be resolved.{reset}\n")
        sys.exit(1)


def audit_diff_against_rules(diff_text: str, rules: list[dict]) -> list[dict]:
    """
    Evaluates a git diff against active architectural rules and invariants.
    Detects:
    1. Layer boundary / Clean Architecture violations (forbidden imports in domain/core).
    2. Multi-tenancy leaks (database queries lacking tenant_id parameter).
    3. Forbidden or deprecated library usages.
    4. Plaintext API keys or secrets in committed code.
    """
    violations = []
    if not diff_text or not rules:
        return violations

    file_diffs = []
    current_file = None
    current_lines = []

    for line in diff_text.splitlines():
        if line.startswith("+++ b/"):
            if current_file:
                file_diffs.append((current_file, current_lines))
            current_file = line[6:].strip()
            current_lines = []
        elif line.startswith("+") and not line.startswith("+++") and current_file:
            current_lines.append(line[1:])

    if current_file:
        file_diffs.append((current_file, current_lines))

    for filepath, added_lines in file_diffs:
        lower_path = filepath.lower()

        for r in rules:
            rule_id = r.get("id")
            rule_name = r.get("name", "")
            rule_lower = rule_name.lower()
            tag = r.get("tag", "rule")

            # 1. Clean Architecture / Layer Boundary Violations
            import_forbidden_match = re.search(r"(?:never|do not|must not|cannot)\s+import\s+([a-zA-Z0-9_\.]+)", rule_lower)
            if import_forbidden_match:
                forbidden_pkg = import_forbidden_match.group(1).strip()
                for line in added_lines:
                    if re.search(rf"\b(?:from|import)\s+{re.escape(forbidden_pkg)}\b", line):
                        violations.append({
                            "severity": "CRITICAL",
                            "type": "layer_violation",
                            "rule_id": rule_id,
                            "rule_name": rule_name,
                            "tag": tag,
                            "file": filepath,
                            "line": line.strip(),
                            "reason": f"Violates layer boundary: prohibited import '{forbidden_pkg}' introduced.",
                            "remediation": f"Refactor '{filepath}' to use dependency injection or invert dependency.",
                        })

            if any(term in rule_lower for term in ("clean architecture", "domain entity", "domain layer")):
                if any(seg in lower_path for seg in ("/domain/", "/core/", "/entities/", "src/domain/")):
                    for line in added_lines:
                        if re.search(r"\b(?:from|import)\s+.*(?:storage|database|postgres|neo4j|qdrant|fastapi|flask)\b", line):
                            violations.append({
                                "severity": "CRITICAL",
                                "type": "clean_architecture_violation",
                                "rule_id": rule_id,
                                "rule_name": rule_name,
                                "tag": tag,
                                "file": filepath,
                                "line": line.strip(),
                                "reason": "Clean Architecture violation: Domain layer must not depend on Infrastructure or Frameworks.",
                                "remediation": "Invert dependency using an abstract interface / repository port.",
                            })

            # 2. Multi-tenancy Guardrail
            if "tenant_id" in rule_lower and any(kw in rule_lower for kw in ("all query", "database query", "filter by", "must filter", "must include")):
                for line in added_lines:
                    if any(term in line for term in (".execute_read(", ".execute_write(", "search_vectors(", "search_hybrid(", "qdrant.search(")):
                        if "tenant_id" not in line and "tenant" not in line:
                            violations.append({
                                "severity": "CRITICAL",
                                "type": "multitenancy_leak",
                                "rule_id": rule_id,
                                "rule_name": rule_name,
                                "tag": tag,
                                "file": filepath,
                                "line": line.strip(),
                                "reason": "Multi-tenancy violation: Database query missing mandatory 'tenant_id' filter.",
                                "remediation": "Pass explicit 'tenant_id' to guarantee cross-tenant data isolation.",
                            })

            # 3. Plaintext Secret / Token Commit
            if any(term in rule_lower for term in ("never commit secret", "never commit key", "never commit token", "no plaintext key")):
                for line in added_lines:
                    if re.search(r"(?:api_key|token|secret|password)\s*=\s*['\"][A-Za-z0-9_\-]{16,}['\"]", line, re.IGNORECASE):
                        violations.append({
                            "severity": "CRITICAL",
                            "type": "hardcoded_secret",
                            "rule_id": rule_id,
                            "rule_name": rule_name,
                            "tag": tag,
                            "file": filepath,
                            "line": line.strip()[:60] + "...",
                            "reason": "Security violation: Potential hardcoded secret or token detected in diff.",
                            "remediation": "Move secrets to environment variables or secret manager.",
                        })

    return violations


def _inject_rules_block(content: str, block: str) -> str:
    """
    Replaces existing managed block or appends to content.
    """
    pattern = re.compile(
        re.escape(MANAGED_START) + r".*?" + re.escape(MANAGED_END),
        re.DOTALL,
    )
    if pattern.search(content):
        return pattern.sub(block, content)
    else:
        if content.strip():
            return content.rstrip() + "\n\n" + block + "\n"
        return block + "\n"


def run_rules_sync(
    target: str = "all",
    project: str | None = None,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Synchronizes active architectural constraints from the knowledge graph into
    AI editor configuration files (CLAUDE.md, .cursorrules, .clinerules, .cursor/rules/veraxi.mdc).
    """
    project_scope = _resolve_project_scope(project)
    active_rules = _get_active_rules(project_scope, tenant_id=tenant_id)

    # Build the managed markdown block
    now_str = _get_utc_now()
    lines = [MANAGED_START, f"## 🧠 Veraxi Architectural Constraints ({project_scope})", f"*Last synced: {now_str}* | Managed by `vx rules sync`\n"]

    if not active_rules:
        lines.append("*No active architectural constraints found. Run `vx remember \"<rule>\"` to add one.*")
    else:
        invariants = [r for r in active_rules if r.get("type") == "invariant" or r.get("tag") == "architecture"]
        guards = [r for r in active_rules if r not in invariants]

        if invariants:
            lines.append("### 🏛 Permanent Architectural Invariants\n")
            for r in invariants:
                proj = r.get("project") or project_scope
                source_info = f" *(from {proj})*" if proj and str(proj).lower() not in (project_scope.lower(), "global", "none") else ""
                tag = r.get("tag", "architecture")
                lines.append(f"- **[{tag}]** {r['name']}{source_info}")
            lines.append("")

        if guards:
            if invariants:
                lines.append("### ⚡ Active Project Guards\n")
            for r in guards:
                proj = r.get("project") or project_scope
                source_info = f" *(from {proj})*" if proj and str(proj).lower() not in (project_scope.lower(), "global", "none") else ""
                tag = r.get("tag", "rule")
                lines.append(f"- **[{tag}]** {r['name']}{source_info}")

    lines.append(MANAGED_END)
    block = "\n".join(lines)

    target = (target or "all").strip().lower()
    root_dir = os.getcwd()
    try:
        import subprocess
        root_dir = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        pass

    target_files = []
    if target in ("claude", "all"):
        target_files.append(os.path.join(root_dir, "CLAUDE.md"))
    if target in ("cursor", "all"):
        target_files.append(os.path.join(root_dir, ".cursorrules"))
        cursor_dir = os.path.join(root_dir, ".cursor", "rules")
        os.makedirs(cursor_dir, exist_ok=True)
        target_files.append(os.path.join(cursor_dir, "veraxi.mdc"))
    if target in ("cline", "all"):
        target_files.append(os.path.join(root_dir, ".clinerules"))

    updated_files = []
    for fpath in target_files:
        try:
            current_content = ""
            if os.path.isfile(fpath):
                with open(fpath, "r", encoding="utf-8") as f:
                    current_content = f.read()

            new_content = _inject_rules_block(current_content, block)
            with open(fpath, "w", encoding="utf-8") as f:
                f.write(new_content)
            updated_files.append(os.path.relpath(fpath, root_dir))
        except Exception as e:
            print(f"Warning: could not update {fpath}: {e}", file=sys.stderr)

    if as_json:
        print(json.dumps({
            "project": project_scope,
            "rules_count": len(active_rules),
            "updated_files": updated_files,
            "rules": active_rules,
        }, indent=2))
        return

    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    reset = "\033[0m"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi AI Editor Rules Synchronization             ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")

    print(f"\n  Project: {bold}{project_scope}{reset}")
    print(f"  {green}✓ Synchronized {len(active_rules)} active constraint(s) across {len(updated_files)} AI config file(s):{reset}")
    for f in updated_files:
        print(f"    • {bold}{f}{reset}")

    print("\n  AI coding agents (Claude Code, Cursor, Cline) now have immediate access")
    print("  to current architectural constraints without token-flooding on resolved issues.\n")
