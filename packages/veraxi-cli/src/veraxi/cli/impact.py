import json
import os
import re
import sys
from veraxi.cli.utils import resolve_project_scope as _resolve_project_scope


def _local_static_impact_scan(target: str, root_dir: str | None = None) -> list[dict]:
    """
    Scans the local repository for references, imports, and calls to the target symbol or file.
    Runs completely offline with zero dependencies.
    """
    if not root_dir:
        try:
            import subprocess
            root_dir = subprocess.check_output(
                ["git", "rev-parse", "--show-toplevel"],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
        except Exception:
            cwd = os.getcwd()
            if cwd in (os.path.expanduser("~"), "/", "/home", "/root"):
                return []
            root_dir = cwd

    symbol = os.path.basename(target).replace(".py", "").replace(".ts", "").replace(".js", "")
    dependents = []
    seen_files = set()

    patterns = [
        re.compile(rf"\bimport\s+.*\b{re.escape(symbol)}\b"),
        re.compile(rf"\bfrom\s+.*\b{re.escape(symbol)}\b"),
        re.compile(rf"\b{re.escape(symbol)}\("),
        re.compile(rf"\b{re.escape(symbol)}\."),
        re.compile(rf"\b{re.escape(target)}\b"),
    ]

    ignore_dirs = {
        ".git", ".venv", "venv", "env", "node_modules", "__pycache__", "dist",
        "build", ".egg-info", ".idea", ".vscode", ".cache", ".local", ".cargo",
        ".rustup", ".gemini", "site-packages"
    }
    code_exts = {".py", ".ts", ".tsx", ".js", ".jsx", ".go", ".rs", ".java", ".cpp", ".c", ".h"}

    scanned_count = 0
    for dirpath, dirnames, filenames in os.walk(root_dir):
        dirnames[:] = [d for d in dirnames if d not in ignore_dirs and not d.startswith(".")]
        for fn in filenames:
            ext = os.path.splitext(fn)[1].lower()
            if ext not in code_exts:
                continue

            scanned_count += 1
            if scanned_count > 2500:
                break

            rel_path = os.path.relpath(os.path.join(dirpath, fn), root_dir)
            if rel_path == target or rel_path in seen_files:
                continue

            full_path = os.path.join(dirpath, fn)
            try:
                with open(full_path, "r", encoding="utf-8", errors="ignore") as f:
                    for line_num, line in enumerate(f, 1):
                        if any(p.search(line) for p in patterns):
                            category = "Internal Modules"
                            norm = rel_path.lower()
                            if any(k in norm for k in ["test", "spec"]):
                                category = "Tests & Verification"
                            elif any(k in norm for k in ["api", "route", "endpoint", "view", "controller"]):
                                category = "Endpoints & APIs"
                            elif any(k in norm for k in ["service", "storage", "client", "core", "model", "db"]):
                                category = "Services & Storage"

                            dependents.append({
                                "name": rel_path,
                                "category": category,
                                "relation": "IMPORTS/CALLS",
                                "line": line_num,
                                "preview": line.strip()[:80],
                            })
                            seen_files.add(rel_path)
                            break
            except Exception:
                continue

    return dependents


def run_impact(
    target: str,
    hops: int = 2,
    project: str | None = None,
    tenant_id: str = "default",
    endpoint: str = "https://api.veraxi.me",
    key: str | None = None,
    root_dir: str | None = None,
    as_json: bool = False,
) -> None:
    """
    Computes architectural blast radius analysis before refactoring or modifying code.
    Identifies downstream callers, dependent services, public endpoints, and required test suites.
    """
    if not target or not target.strip():
        print("Error: target symbol or file path is required for impact analysis.", file=sys.stderr)
        sys.exit(1)

    target = target.strip()
    hops = min(max(1, hops), 4)
    project_scope = _resolve_project_scope(project)

    dependents: list[dict] = []
    source_type = "static_ast"

    # 1. Attempt Neo4j Knowledge Graph Traversal
    try:
        from backend.config import get_config
        from backend.storage.neo4j_client import Neo4jStorageClient

        config = get_config()
        neo4j = Neo4jStorageClient.from_config(config)

        query = f"""
        MATCH (target)
        WHERE (toLower(target.name) CONTAINS toLower($target)
           OR target.id = $target)
          AND (target.tenant_id = $tenant_id OR target.tenant_id = 'default' OR target.tenant_id IS NULL)
        MATCH path = (dependent)-[r*1..{hops}]->(target)
        WHERE dependent <> target
        RETURN DISTINCT dependent.name as name,
               labels(dependent) as labels,
               [rel in relationships(path) | type(rel)] as rels
        LIMIT 50
        """
        rows = neo4j.execute_read(query, {"target": target, "tenant_id": tenant_id})
        neo4j.close()

        if rows:
            source_type = "knowledge_graph"
            for r in rows:
                name = r.get("name") or "Unknown"
                labels = r.get("labels") or []
                norm = (name + " " + " ".join(labels)).lower()

                category = "Internal Modules"
                if any(k in norm for k in ["test", "spec"]):
                    category = "Tests & Verification"
                elif any(k in norm for k in ["endpoint", "api", "route", "view", "controller", "/", "post ", "get "]):
                    category = "Endpoints & APIs"
                elif any(k in norm for k in ["service", "storage", "client", "model", "db", "repository"]):
                    category = "Services & Storage"

                rels = r.get("rels") or ["DEPENDS_ON"]
                dependents.append({
                    "name": name,
                    "category": category,
                    "relation": rels[0] if rels else "DEPENDS_ON",
                    "filepath": None,
                })
    except Exception:
        pass

    # 2. Fallback to Local Static AST Scan if Graph has no nodes
    if not dependents:
        dependents = _local_static_impact_scan(target, root_dir=root_dir)

    # 3. Categorize and compute risk level
    total = len(dependents)
    if total == 0:
        risk_level = "LOW"
    elif total <= 2:
        risk_level = "LOW"
    elif total <= 5:
        risk_level = "MEDIUM"
    elif total <= 10:
        risk_level = "HIGH"
    else:
        risk_level = "CRITICAL"

    by_category: dict[str, list[dict]] = {
        "Endpoints & APIs": [],
        "Services & Storage": [],
        "Internal Modules": [],
        "Tests & Verification": [],
    }
    for d in dependents:
        cat = d.get("category", "Internal Modules")
        if cat not in by_category:
            by_category[cat] = []
        by_category[cat].append(d)

    required_tests = [d["name"] for d in by_category["Tests & Verification"]]

    output_data = {
        "target": target,
        "project": project_scope,
        "risk_level": risk_level,
        "total_dependents": total,
        "source": source_type,
        "dependents": dependents,
        "by_category": by_category,
        "required_tests": required_tests,
    }

    if as_json:
        print(json.dumps(output_data, indent=2))
        return

    # 4. Colorized ANSI Visualization
    bold = "\033[1m"
    cyan = "\033[36m"
    green = "\033[32m"
    yellow = "\033[33m"
    red = "\033[31m"
    reset = "\033[0m"

    if risk_level == "LOW":
        risk_badge = f"{green}{bold}LOW{reset}"
    elif risk_level == "MEDIUM":
        risk_badge = f"{yellow}{bold}MEDIUM{reset}"
    elif risk_level == "HIGH":
        risk_badge = f"{red}{bold}HIGH{reset}"
    else:
        risk_badge = f"\033[41m\033[37m{bold} CRITICAL {reset}"

    print(f"\n{bold}{cyan}╔════════════════════════════════════════════════════════════════════╗{reset}")
    print(f"{bold}{cyan}║                 Veraxi Architectural Blast Radius                  ║{reset}")
    print(f"{bold}{cyan}╚════════════════════════════════════════════════════════════════════╝{reset}")

    print(f"\n  Target: {bold}{target}{reset} (Scope: {project_scope} | Source: {source_type})")
    print(f"  Risk Level: {risk_badge} ({total} downstream dependents across {len([k for k, v in by_category.items() if v])} domains)")

    if total == 0:
        print(f"\n  {green}✓ No downstream dependencies found.{reset}")
        print("    This component appears to be an isolated module or leaf node.")
        print("    Safe to refactor with minimal blast radius risk.\n")
        return

    print("\n  Downstream Blast Radius Tree:")
    cat_keys = [k for k in ["Endpoints & APIs", "Services & Storage", "Internal Modules", "Tests & Verification"] if by_category.get(k)]
    for i, cat in enumerate(cat_keys):
        is_last_cat = (i == len(cat_keys) - 1)
        cat_branch = "└──" if is_last_cat else "├──"
        print(f"  {cat_branch} {bold}{cat}{reset} ({len(by_category[cat])})")
        items = by_category[cat]
        for j, item in enumerate(items):
            is_last_item = (j == len(items) - 1)
            child_prefix = "    " if is_last_cat else "│   "
            item_branch = "└──" if is_last_item else "├──"
            rel = f" \033[2m({item.get('relation', 'DEPENDS_ON')})\033[0m"
            print(f"  {child_prefix}{item_branch} {item['name']}{rel}")

    print(f"\n  {bold}Actionable Guidance for AI Agent / Engineer:{reset}")
    if by_category.get("Endpoints & APIs"):
        print(f"  • {yellow}Warning:{reset} Modifying '{target}' directly affects {len(by_category['Endpoints & APIs'])} public API endpoint(s). Check API contracts.")
    if required_tests:
        test_str = ", ".join(required_tests[:4]) + ("..." if len(required_tests) > 4 else "")
        print(f"  • {green}Required Verification:{reset} Execute test suites before committing: {bold}{test_str}{reset}")
    else:
        print(f"  • {yellow}Notice:{reset} No automated tests found directly covering this component. Add a test suite.")
    print()
