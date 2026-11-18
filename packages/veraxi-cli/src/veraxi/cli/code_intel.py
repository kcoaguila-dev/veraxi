"""Repo X-Ray and Vuln Intel CLI (WP2).

HTTP primary via backend/routes/code_intel.py:
- POST /api/v1/code/ingest {repo_path}
- GET  /api/v1/code/symbol?name=
- GET  /api/v1/code/impact?symbol=&max_depth=
- POST /api/v1/vuln/sync
- POST /api/v1/vuln/report {repo_path} or {dependencies}

The server validates repo_path against its allowed roots (/app or
VERAXI_CODE_ROOTS); its rejection message is surfaced verbatim by
http_client — the CLI never bypasses it.
Exit codes: 0 ok, 1 error, 2 --fail-on gate failed (vuln report).
"""

import ast
import json
import re
import sys
from pathlib import Path

_SEVERITY_RANK = {"none": 0, "low": 1, "medium": 2, "moderate": 2, "high": 3, "critical": 4}


def _print_result(data, as_json, render):
    if as_json:
        print(json.dumps(data, indent=2))
        return
    render(data)


_LOCAL_EXTENSIONS = {".py": "python", ".dart": "dart", ".js": "javascript",
                     ".jsx": "javascript", ".mjs": "javascript", ".cjs": "javascript",
                     ".ts": "typescript", ".tsx": "typescript"}
_LOCAL_SKIPPED_DIRS = {"node_modules", "vendor", ".git", "dist", "build", "__pycache__"}
_LOCAL_IMPORT_RE = re.compile(r"""^\s*import\s+(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]""")


def _local_module_qn(relative_path):
    """Dotted module name, honouring src layouts (mirrors the backend).

    ``packages/<pkg>/src/<pkg>/cli/main.py`` -> ``<pkg>.cli.main``.
    """
    stem = relative_path.rsplit(".", 1)[0] if "." in relative_path else relative_path
    parts = [part for part in stem.replace("\\", "/").split("/") if part]
    if len(parts) >= 4 and parts[0] == "packages" and parts[2] == "src":
        parts = parts[3:]
    elif len(parts) >= 2 and parts[0] == "src":
        parts = parts[1:]
    elif len(parts) >= 3 and parts[1] == "src":
        parts = parts[2:]
    if relative_path.endswith(".py"):
        parts = [part.replace("-", "_") for part in parts]
    if parts and parts[-1] == "__init__":
        parts = parts[:-1]
    return ".".join(parts)


def _local_node(nodes, seen, label, name, qn, path, line, language, resolved=True):
    if (label, qn) in seen:
        return
    seen.add((label, qn))
    nodes.append({"label": label, "name": name, "qualified_name": qn, "path": path,
                  "line": line, "language": language, "resolved": resolved})


def _parse_python_locally(tree, module_qn, relative, nodes, edges, seen):
    for node in tree.body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                edges.append({"type": "IMPORTS", "source_qn": module_qn, "source_label": "CodeModule",
                              "target_qn": alias.name, "target_label": "CodeModule"})
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                edges.append({"type": "IMPORTS", "source_qn": module_qn, "source_label": "CodeModule",
                              "target_qn": node.module, "target_label": "CodeModule"})
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            qn = f"{module_qn}.{node.name}"
            _local_node(nodes, seen, "Function", node.name, qn, relative, node.lineno, "python")
            edges.append({"type": "DEFINES", "source_qn": module_qn, "source_label": "CodeModule",
                          "target_qn": qn, "target_label": "Function"})
        elif isinstance(node, ast.ClassDef):
            qn = f"{module_qn}.{node.name}"
            _local_node(nodes, seen, "Class", node.name, qn, relative, node.lineno, "python")
            edges.append({"type": "DEFINES", "source_qn": module_qn, "source_label": "CodeModule",
                          "target_qn": qn, "target_label": "Class"})
            for child in node.body:
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    mqn = f"{qn}.{child.name}"
                    _local_node(nodes, seen, "Function", child.name, mqn, relative, child.lineno, "python")
                    edges.append({"type": "DEFINES", "source_qn": qn, "source_label": "Class",
                                  "target_qn": mqn, "target_label": "Function"})


def parse_repo_locally(repo_path):
    """Parse a local repo into an ingest-graph payload (client-side).

    The CLI distribution is standalone (no backend package), so this is
    the client-side counterpart of the backend parser: stdlib ``ast``
    for Python, import-edge-only for Dart/JS/TS. Returns
    ``{"repo_name", "nodes", "edges"}`` for POST /api/v1/code/ingest-graph.
    """
    root = Path(repo_path)
    nodes, edges, seen = [], [], set()
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(root).as_posix()
        if any(part in _LOCAL_SKIPPED_DIRS for part in relative.split("/")[:-1]):
            continue
        language = _LOCAL_EXTENSIONS.get(path.suffix.lower())
        if language is None:
            continue
        module_qn = _local_module_qn(relative)
        _local_node(nodes, seen, "CodeFile", path.name, relative, relative, 1, language)
        _local_node(nodes, seen, "CodeModule", module_qn.rsplit(".", 1)[-1], module_qn, relative, 1, language)
        edges.append({"type": "DEFINES", "source_qn": relative, "source_label": "CodeFile",
                      "target_qn": module_qn, "target_label": "CodeModule"})
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if language == "python":
            try:
                tree = ast.parse(text, filename=relative)
            except SyntaxError:
                continue
            _parse_python_locally(tree, module_qn, relative, nodes, edges, seen)
        else:
            for line in text.splitlines():
                match = _LOCAL_IMPORT_RE.search(line)
                if match:
                    edges.append({"type": "IMPORTS", "source_qn": module_qn, "source_label": "CodeModule",
                                  "target_qn": match.group(1), "target_label": "CodeModule"})
    return {"repo_name": root.name, "nodes": nodes, "edges": edges}


def run_xray_index(repo_path, endpoint=None, key=None, tenant=None, as_json=False, local=False):
    from veraxi.cli.http_client import api_request

    if local:
        # Parse on this machine and upload the graph: the server never
        # needs filesystem access to the repo.
        payload = parse_repo_locally(repo_path)
        data = api_request("POST", "/api/v1/code/ingest-graph", body=payload,
                           endpoint=endpoint, key=key, tenant=tenant, timeout=300)
        _print_result(data, as_json, lambda d: print(
            f"Indexed local {payload['repo_name']}: {json.dumps({k: v for k, v in d.items() if k not in ('status', 'repo_name')})}"
        ))
        sys.exit(0)
    data = api_request("POST", "/api/v1/code/ingest", body={"repo_path": repo_path},
                       endpoint=endpoint, key=key, tenant=tenant, timeout=300)
    _print_result(data, as_json, lambda d: print(
        f"Indexed {d.get('repo_path')}: {json.dumps({k: v for k, v in d.items() if k not in ('status', 'repo_path')})}"
    ))
    sys.exit(0)


def run_xray_symbol(name, endpoint=None, key=None, tenant=None, as_json=False, resolved_only=False):
    from veraxi.cli.http_client import api_request

    data = api_request("GET", "/api/v1/code/symbol", endpoint=endpoint, key=key,
                       tenant=tenant, params={"name": name})
    if resolved_only and isinstance(data, dict):
        for field in ("symbols", "matches"):
            if isinstance(data.get(field), list):
                data = {**data, field: [s for s in data[field] if s.get("resolved", True)]}
                break

    def render(d):
        symbols = d.get("symbols") or d.get("matches") or []
        if isinstance(d, dict) and not symbols and d:
            print(json.dumps(d, indent=2))
            return
        for sym in symbols:
            suffix = "" if sym.get("resolved", True) else " [external/unresolved]"
            print(f"{sym.get('qualified_name') or sym.get('name')} ({sym.get('label')}) {sym.get('path', '')}:{sym.get('line', '')}{suffix}")

    _print_result(data, as_json, render)
    sys.exit(0)


def run_xray_impact(name, endpoint=None, key=None, tenant=None, as_json=False, max_depth=3):
    from veraxi.cli.http_client import api_request

    data = api_request("GET", "/api/v1/code/impact", endpoint=endpoint, key=key,
                       tenant=tenant, params={"symbol": name, "max_depth": max_depth})

    def render(d):
        print(json.dumps(d, indent=2))

    _print_result(data, as_json, render)
    sys.exit(0)


def run_vuln_sync(endpoint=None, key=None, tenant=None, as_json=False):
    from veraxi.cli.http_client import api_request

    data = api_request("POST", "/api/v1/vuln/sync", body={}, endpoint=endpoint, key=key, tenant=tenant, timeout=120)
    _print_result(data, as_json, lambda d: print(f"Vuln sync: {json.dumps(d)}"))
    sys.exit(0)


def _load_deps_file(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Error: invalid deps JSON in {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    if isinstance(data, dict):
        data = data.get("dependencies")
    if not isinstance(data, list):
        print("Error: deps file must be a JSON list or {\"dependencies\": [...]}", file=sys.stderr)
        sys.exit(1)
    return data


def _gate_failed(data, fail_on):
    if not fail_on:
        return False
    threshold = _SEVERITY_RANK.get(str(fail_on).lower())
    if threshold is None:
        return False
    for finding in data.get("findings") or []:
        severity = str(finding.get("severity") or "").lower()
        if _SEVERITY_RANK.get(severity, 0) >= threshold:
            return True
    return False


def run_vuln_report(repo_path=None, deps=None, endpoint=None, key=None, tenant=None,
                    as_json=False, fail_on=None):
    from veraxi.cli.http_client import api_request

    body = {}
    if deps:
        body["dependencies"] = _load_deps_file(deps)
    elif repo_path:
        body["repo_path"] = repo_path
    else:
        print("Error: provide a repo path or --deps file.", file=sys.stderr)
        sys.exit(1)
    data = api_request("POST", "/api/v1/vuln/report", body=body, endpoint=endpoint, key=key, tenant=tenant)

    def render(d):
        print(f"Dependencies checked: {d.get('dependencies_checked')}  matched: {d.get('matched_count')}  unknown: {d.get('unknown_count')}  KEV: {d.get('kev_count')}")
        for f in d.get("findings") or []:
            print(f"  [{f.get('severity')}] {f.get('cve_id')} {f.get('package')}@{f.get('version')} ({f.get('match_status')})")

    _print_result(data, as_json, render)
    if _gate_failed(data, fail_on):
        print(f"Gate failed: findings at or above severity '{fail_on}'", file=sys.stderr)
        sys.exit(2)
    sys.exit(0)
