"""Repo X-Ray and Vuln Intel CLI (WP2).

HTTP primary via backend/routes/code_intel.py:
- POST /api/v1/code/ingest {repo_path}
- POST /api/v1/code/update {repo_path} (incremental refresh)
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
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
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
_LOCAL_SKIPPED_DIRS = {
    "node_modules",
    "vendor",
    ".git",
    "dist",
    "build",
    "__pycache__",
    ".venv",
    "venv",
    "env",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".dart_tool",
    "site-packages",
}
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


def _local_node(nodes, seen, label, name, qn, path, line, language, resolved=True,
                end_line=None):
    if (label, qn) in seen:
        return
    seen.add((label, qn))
    node = {"label": label, "name": name, "qualified_name": qn, "path": path,
            "line": line, "language": language, "resolved": resolved}
    if end_line is not None:
        node["end_line"] = end_line
    nodes.append(node)


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
            _local_node(nodes, seen, "Function", node.name, qn, relative, node.lineno, "python",
                        end_line=node.end_lineno)
            edges.append({"type": "DEFINES", "source_qn": module_qn, "source_label": "CodeModule",
                          "target_qn": qn, "target_label": "Function"})
        elif isinstance(node, ast.ClassDef):
            qn = f"{module_qn}.{node.name}"
            _local_node(nodes, seen, "Class", node.name, qn, relative, node.lineno, "python",
                        end_line=node.end_lineno)
            edges.append({"type": "DEFINES", "source_qn": module_qn, "source_label": "CodeModule",
                          "target_qn": qn, "target_label": "Class"})
            for child in node.body:
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    mqn = f"{qn}.{child.name}"
                    _local_node(nodes, seen, "Function", child.name, mqn, relative, child.lineno, "python",
                                end_line=child.end_lineno)
                    edges.append({"type": "DEFINES", "source_qn": qn, "source_label": "Class",
                                  "target_qn": mqn, "target_label": "Function"})


def _local_git_head(root):
    """The HEAD commit SHA of the checkout at ``root``, or None.

    Provenance for the ingest payload: the server stamps it into the
    index metadata verbatim. None when ``root`` is not a git checkout
    — the commit is then unknown, never guessed.
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def parse_repo_locally(repo_path):
    """Parse a local repo into an ingest-graph payload (client-side).

    The CLI distribution is standalone (no backend package), so this is
    the client-side counterpart of the backend parser: stdlib ``ast``
    for Python, import-edge-only for Dart/JS/TS. Returns
    ``{"repo_name", "nodes", "edges"}`` for POST /api/v1/code/ingest-graph.
    """
    root = Path(repo_path).resolve()
    nodes, edges, seen = [], [], set()
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d not in _LOCAL_SKIPPED_DIRS)
        for filename in sorted(filenames):
            path = Path(dirpath) / filename
            if path.is_symlink():
                continue
            relative = path.relative_to(root).as_posix()
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
    return {
        "repo_name": root.name,
        "nodes": nodes,
        "edges": edges,
        "source_commit": _local_git_head(root),
    }


def run_xray_index(repo_path, endpoint=None, key=None, tenant=None, as_json=False, local=False, update=False):
    from veraxi.cli.http_client import api_request

    if update and not local:
        # Incremental refresh of an already-indexed repo: the server
        # diffs its index stamp against the checkout and re-parses
        # only the changed files (POST /api/v1/code/update).
        data = api_request("POST", "/api/v1/code/update", body={"repo_path": repo_path},
                           endpoint=endpoint, key=key, tenant=tenant, timeout=300)
        _print_result(data, as_json, lambda d: print(
            f"Updated {d.get('repo_path')}: {json.dumps({k: v for k, v in d.items() if k not in ('status', 'repo_path')})}"
        ))
        sys.exit(0)
    if update and local:
        # A local parse uploads a full graph snapshot; there is no
        # incremental upload, so --update degrades to a full re-index
        # rather than pretending otherwise.
        print(
            "Note: --update applies to server-side indexing; "
            "performing a full local re-index instead.",
            file=sys.stderr,
        )
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


def _derive_repo_key(repo_path):
    """Canonical repo key for ``repo_path``, mirroring the backend's
    ``derive_repo_key`` (backend/ingestion/code_graph.py) — the CLI is
    a standalone distribution with no backend package, so the logic is
    replicated here and must be kept in step with it: the git origin
    slug ``owner/repo`` when the checkout has an origin remote,
    otherwise the checkout's resolved absolute path.
    """
    root = Path(repo_path).resolve()
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        result = None
    if result is not None and result.returncode == 0:
        url = result.stdout.strip().rstrip("/").removesuffix(".git")
        parts = [p for p in re.split(r"[/:]", url) if p]
        if len(parts) >= 2:
            return f"{parts[-2]}/{parts[-1]}"
    return str(root)


def run_xray_index_scip(scip_path, endpoint=None, key=None, tenant=None, as_json=False, repo_key=None):
    """Upload a SCIP JSON index (``scip print --json`` output) to /api/v1/code/ingest-scip."""
    from veraxi.cli.http_client import api_request

    try:
        payload = json.loads(Path(scip_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Error: invalid SCIP JSON in {scip_path}: {exc}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(payload, dict) or not isinstance(payload.get("documents"), list):
        print(f"Error: SCIP JSON in {scip_path} must be an object with a documents list", file=sys.stderr)
        sys.exit(1)
    body = {"scip": payload}
    if repo_key:
        body["repo_key"] = repo_key
    data = api_request("POST", "/api/v1/code/ingest-scip", body=body,
                       endpoint=endpoint, key=key, tenant=tenant, timeout=300,
                       gzip_body=True)
    _print_result(data, as_json, lambda d: print(
        f"SCIP indexed {scip_path}: nodes={d.get('nodes_written', 0)} edges={d.get('edges_written', 0)}"
    ))
    sys.exit(0)


def _scip_tool_binary(name, env_var, extra_candidates=()):
    """Resolve a SCIP tool binary: explicit env override, PATH, or fallback paths."""
    override = os.environ.get(env_var)
    if override:
        return override
    found = shutil.which(name)
    if found:
        return found
    for candidate in extra_candidates:
        if Path(candidate).is_file():
            return str(candidate)
    return None


def _detect_scip_language(repo, lang):
    """Resolve ``auto`` language for ``--generate-scip`` from repo manifests."""
    normalized = (lang or "auto").strip().lower()
    if normalized in ("python", "dart"):
        return normalized
    if (repo / "pubspec.yaml").is_file():
        return "dart"
    return "python"


def _repo_head_version(repo):
    """Git HEAD SHA of ``repo`` as the SCIP project version, else None."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    sha = result.stdout.strip() if result.returncode == 0 else ""
    return sha or None


def _prepare_scip_index_command(repo, index_path, language):
    """Resolve indexer binary + argv for ``language`` (python or dart)."""
    if language == "dart":
        if not (repo / ".dart_tool" / "package_config.json").is_file():
            print(
                "Error: Dart package config not found (.dart_tool/package_config.json). "
                "Run 'flutter pub get' or 'dart pub get' first.",
                file=sys.stderr,
            )
            sys.exit(1)
        scip_dart = _scip_tool_binary(
            "scip_dart",
            "VERAXI_SCIP_DART_BIN",
            extra_candidates=(Path.home() / ".pub-cache" / "bin" / "scip_dart",),
        )
        if not scip_dart:
            print(
                "Error: Dart SCIP generation needs `scip_dart` "
                "(dart pub global activate scip_dart) on PATH or in "
                "~/.pub-cache/bin, or VERAXI_SCIP_DART_BIN set.",
                file=sys.stderr,
            )
            sys.exit(1)
        return [scip_dart, "-o", str(index_path), str(repo)], "scip_dart"

    scip_python = _scip_tool_binary("scip-python", "VERAXI_SCIP_PYTHON_BIN")
    if not scip_python:
        print(
            "Error: SCIP generation needs both `scip-python` "
            "(npm: @sourcegraph/scip-python) and the `scip` CLI "
            "(sourcegraph/scip releases) on PATH, or "
            "VERAXI_SCIP_PYTHON_BIN / VERAXI_SCIP_BIN set.",
            file=sys.stderr,
        )
        sys.exit(1)
    version = _repo_head_version(repo) or "0.0.0"
    return [
        scip_python, "index", "--cwd", str(repo),
        "--project-name", repo.name, "--project-version", version,
        "--output", str(index_path),
    ], "scip-python"


def run_xray_index_generate_scip(
    repo_path, endpoint=None, key=None, tenant=None, as_json=False, lang="auto"
):
    """Generate a SCIP index locally and upload it (ADR-0007 Phase 4 / ADR-0008).

    Runs ``scip-python index`` (Python) or ``scip_dart`` (Dart) and
    ``scip print --json`` on *this* machine — the local runner / CI
    case, never the hosted backend — then uploads through the existing
    ``--scip`` path (:func:`run_xray_index_scip`). Both indexers are
    operator-installed CLI tools, never backend dependencies; binaries
    resolve via ``VERAXI_SCIP_PYTHON_BIN`` / ``VERAXI_SCIP_DART_BIN`` /
    ``VERAXI_SCIP_BIN`` or PATH.
    """
    repo = Path(repo_path)
    if not repo.is_dir():
        print(f"Error: repo path {repo_path} is not a directory", file=sys.stderr)
        sys.exit(1)
    language = _detect_scip_language(repo, lang)
    scip_cli = _scip_tool_binary("scip", "VERAXI_SCIP_BIN")
    if not scip_cli:
        print(
            "Error: SCIP generation needs the `scip` CLI "
            "(sourcegraph/scip releases) on PATH or VERAXI_SCIP_BIN set.",
            file=sys.stderr,
        )
        sys.exit(1)
    with tempfile.TemporaryDirectory() as tmp:
        index_path = Path(tmp) / "index.scip"
        index_cmd, tool_label = _prepare_scip_index_command(repo, index_path, language)
        try:
            indexed = subprocess.run(index_cmd, capture_output=True, text=True, timeout=1800, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            print(f"Error: {tool_label} failed to run: {exc}", file=sys.stderr)
            sys.exit(1)
        if indexed.returncode != 0 or not index_path.exists():
            print(
                f"Error: {tool_label} failed ({indexed.returncode}): "
                f"{(indexed.stderr or '')[-500:]}",
                file=sys.stderr,
            )
            sys.exit(1)
        try:
            printed = subprocess.run(
                [scip_cli, "print", "--json", str(index_path)],
                capture_output=True, text=True, timeout=600, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            print(f"Error: scip print failed to run: {exc}", file=sys.stderr)
            sys.exit(1)
        if printed.returncode != 0 or not printed.stdout.strip():
            print(
                f"Error: scip print failed ({printed.returncode}): "
                f"{(printed.stderr or '')[-500:]}",
                file=sys.stderr,
            )
            sys.exit(1)
        json_path = Path(tmp) / "index.scip.json"
        json_path.write_text(printed.stdout, encoding="utf-8")
        # Stamp the upload with the canonical repo key (same identity
        # an AST ingest of this checkout derives server-side), so the
        # SCIP graph replaces the AST graph of covered files in that
        # partition instead of landing under metadata.project_root.
        run_xray_index_scip(
            str(json_path), endpoint=endpoint, key=key, tenant=tenant,
            as_json=as_json, repo_key=_derive_repo_key(repo),
        )


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


_VERSION_BASE_RE = re.compile(r"(\d+(?:\.\d+)*)")
_PEP508_SPLIT_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?\s*(.*)$")


def _parse_local_version(spec):
    text = (spec or "").strip()
    if not text or text in ("*", "any", "latest") or text.startswith(("git+", "git:", "http://", "https://", "file:", "path:")):
        return None
    m = _VERSION_BASE_RE.search(text)
    return m.group(1) if m else None


def _extract_pyproject_deps(path, relative):
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return []
    raw = list((data.get("project") or {}).get("dependencies") or [])
    for group in ((data.get("project") or {}).get("optional-dependencies") or {}).values():
        if isinstance(group, list):
            raw.extend(group)
    deps = []
    for entry in raw:
        if not isinstance(entry, str):
            continue
        m = _PEP508_SPLIT_RE.match(entry.split(";")[0].strip())
        if not m:
            continue
        deps.append({"name": m.group(1).lower(), "version": _parse_local_version(m.group(2)),
                     "ecosystem": "pypi", "source_file": relative})
    return deps


def _extract_package_json_deps(path, relative):
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return []
    deps = []
    for section in ("dependencies", "devDependencies"):
        block = data.get(section)
        if not isinstance(block, dict):
            continue
        for name, spec in block.items():
            if isinstance(spec, str):
                deps.append({"name": str(name).lower(), "version": _parse_local_version(spec),
                             "ecosystem": "npm", "source_file": relative})
    return deps


def _extract_uv_lock_deps(path, relative):
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return []
    deps = []
    for pkg in data.get("package") or []:
        if not isinstance(pkg, dict):
            continue
        source = pkg.get("source")
        if isinstance(source, dict) and ("editable" in source or "virtual" in source):
            continue
        name, version = pkg.get("name"), pkg.get("version")
        if isinstance(name, str) and isinstance(version, str) and version:
            deps.append({"name": name.lower(), "version": version,
                         "ecosystem": "pypi", "source_file": relative})
    return deps


def _extract_package_lock_deps(path, relative):
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return []
    deps, seen = [], set()
    packages = data.get("packages") if isinstance(data, dict) else None
    if isinstance(packages, dict):
        for pkg_path, info in packages.items():
            if not pkg_path or "node_modules/" not in pkg_path or not isinstance(info, dict):
                continue
            name = pkg_path.rsplit("node_modules/", 1)[-1].lower()
            version = info.get("version")
            if isinstance(version, str) and version and (name, version) not in seen:
                seen.add((name, version))
                deps.append({"name": name, "version": version,
                             "ecosystem": "npm", "source_file": relative})
    return deps


def extract_deps_locally(repo_path):
    """Extract dependencies from local manifests and lockfiles (for ``vuln report --local``)."""
    root = Path(repo_path).resolve()
    deps = []
    extractors = {
        "pyproject.toml": _extract_pyproject_deps,
        "package.json": _extract_package_json_deps,
        "uv.lock": _extract_uv_lock_deps,
        "package-lock.json": _extract_package_lock_deps,
    }
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d not in _LOCAL_SKIPPED_DIRS)
        for filename in sorted(filenames):
            extractor = extractors.get(filename)
            if extractor is None:
                continue
            path = Path(dirpath) / filename
            if path.is_symlink():
                continue
            relative = path.relative_to(root).as_posix()
            deps.extend(extractor(path, relative))
    return deps


def run_vuln_report(repo_path=None, deps=None, sbom=None, endpoint=None, key=None, tenant=None,
                    as_json=False, fail_on=None, live_osv=False, local=False, reachability=False):
    from veraxi.cli.http_client import api_request

    body = {}
    if deps:
        body["dependencies"] = _load_deps_file(deps)
    elif sbom:
        try:
            body["sbom_json"] = json.loads(Path(sbom).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"Error: invalid SBOM JSON in {sbom}: {exc}", file=sys.stderr)
            sys.exit(1)
    elif local:
        body["dependencies"] = extract_deps_locally(repo_path or ".")
    elif repo_path:
        body["repo_path"] = repo_path
    else:
        print("Error: provide a repo path, --local, --deps, or --sbom file.", file=sys.stderr)
        sys.exit(1)
    if live_osv:
        body["live_osv"] = True
    if reachability:
        body["include_reachability"] = True
    data = api_request("POST", "/api/v1/vuln/report", body=body, endpoint=endpoint, key=key, tenant=tenant,
                       timeout=120 if live_osv else 30)

    def render(d):
        print(f"Dependencies checked: {d.get('dependencies_checked')}  matched: {d.get('matched_count')}  unknown: {d.get('unknown_count')}  KEV: {d.get('kev_count')}")
        for f in d.get("findings") or []:
            epss = f" EPSS={f['epss_score']:.2f}" if f.get("epss_score") is not None else ""
            reach = f" files={f['reachable_file_count']}" if "reachable_file_count" in f else ""
            print(f"  [{f.get('severity')}] {f.get('cve_id')} {f.get('package')}@{f.get('version')} ({f.get('match_status')}){epss}{reach}")

    _print_result(data, as_json, render)
    if _gate_failed(data, fail_on):
        print(f"Gate failed: findings at or above severity '{fail_on}'", file=sys.stderr)
        sys.exit(2)
    sys.exit(0)


def run_vuln_sarif(sarif_path, endpoint=None, key=None, tenant=None, as_json=False):
    """Upload a SARIF 2.1.0 JSON file to /api/v1/vuln/sarif."""
    from veraxi.cli.http_client import api_request

    try:
        sarif = json.loads(Path(sarif_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Error: invalid SARIF JSON in {sarif_path}: {exc}", file=sys.stderr)
        sys.exit(1)
    data = api_request("POST", "/api/v1/vuln/sarif", body={"sarif": sarif},
                       endpoint=endpoint, key=key, tenant=tenant, timeout=120)
    _print_result(data, as_json, lambda d: print(
        f"SARIF ingested: findings={d.get('findings_written', 0)} file_links={d.get('file_links', 0)} cwe_links={d.get('cwe_links', 0)}"
    ))
    sys.exit(0)


def run_vuln_attack_sync(stix_path=None, endpoint=None, key=None, tenant=None, as_json=False):
    """Sync MITRE ATT&CK (STIX 2.1) into /api/v1/vuln/attack/sync."""
    from veraxi.cli.http_client import api_request

    body = {}
    if stix_path:
        try:
            body["stix_json"] = json.loads(Path(stix_path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"Error: invalid STIX JSON in {stix_path}: {exc}", file=sys.stderr)
            sys.exit(1)
    data = api_request("POST", "/api/v1/vuln/attack/sync", body=body,
                       endpoint=endpoint, key=key, tenant=tenant, timeout=180)
    _print_result(data, as_json, lambda d: print(f"ATT&CK sync: {json.dumps(d)}"))
    sys.exit(0)


def run_vuln_recon(nuclei_path, endpoint=None, key=None, tenant=None, as_json=False):
    """Upload a Nuclei JSON or JSONL file to /api/v1/vuln/recon."""
    from veraxi.cli.http_client import api_request

    try:
        raw = Path(nuclei_path).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"Error: unreadable Nuclei file {nuclei_path}: {exc}", file=sys.stderr)
        sys.exit(1)
    data = api_request("POST", "/api/v1/vuln/recon", body={"nuclei": raw},
                       endpoint=endpoint, key=key, tenant=tenant, timeout=120)
    _print_result(data, as_json, lambda d: print(
        f"Recon ingested: findings={d.get('findings_written', 0)} hosts={d.get('host_links', 0)} cves={d.get('cve_links', 0)}"
    ))
    sys.exit(0)
