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

import json
import sys
from pathlib import Path

_SEVERITY_RANK = {"none": 0, "low": 1, "medium": 2, "moderate": 2, "high": 3, "critical": 4}


def _print_result(data, as_json, render):
    if as_json:
        print(json.dumps(data, indent=2))
        return
    render(data)


def run_xray_index(repo_path, endpoint=None, key=None, tenant=None, as_json=False):
    from veraxi.cli.http_client import api_request

    data = api_request("POST", "/api/v1/code/ingest", body={"repo_path": repo_path},
                       endpoint=endpoint, key=key, tenant=tenant)
    _print_result(data, as_json, lambda d: print(
        f"Indexed {d.get('repo_path')}: {json.dumps({k: v for k, v in d.items() if k not in ('status', 'repo_path')})}"
    ))
    sys.exit(0)


def run_xray_symbol(name, endpoint=None, key=None, tenant=None, as_json=False):
    from veraxi.cli.http_client import api_request

    data = api_request("GET", "/api/v1/code/symbol", endpoint=endpoint, key=key,
                       tenant=tenant, params={"name": name})

    def render(d):
        symbols = d.get("symbols") or d.get("matches") or []
        if isinstance(d, dict) and not symbols and d:
            print(json.dumps(d, indent=2))
            return
        for sym in symbols:
            print(f"{sym.get('qualified_name') or sym.get('name')} ({sym.get('label')}) {sym.get('path', '')}:{sym.get('line', '')}")

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

    data = api_request("POST", "/api/v1/vuln/sync", body={}, endpoint=endpoint, key=key, tenant=tenant)
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
