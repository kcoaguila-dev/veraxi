"""Corpus briefing and dbt lineage CLI (WP3).

HTTP via backend/routes/corpus_insights.py:
- GET  /api/v1/corpus/briefing -> {**briefing, markdown}
- POST /api/v1/dbt/ingest {manifest} (manifest must carry a 'nodes' mapping)
- GET  /api/v1/dbt/datasets?q= -> {query, matches[{..., matched_by, upstream, downstream}]}
Exit codes: 0 ok, 1 error (including invalid manifest JSON locally).
"""

import json
import sys
from pathlib import Path


def run_briefing(endpoint=None, key=None, tenant=None, as_json=False, out=None):
    from veraxi.cli.http_client import api_request

    data = api_request("GET", "/api/v1/corpus/briefing", endpoint=endpoint, key=key, tenant=tenant)
    if as_json:
        print(json.dumps(data, indent=2))
        sys.exit(0)
    markdown = data.get("markdown") or ""
    if out:
        try:
            Path(out).write_text(markdown, encoding="utf-8")
        except OSError as exc:
            print(f"Error: could not write {out}: {exc}", file=sys.stderr)
            sys.exit(1)
        print(f"Wrote briefing to {out}")
    else:
        print(markdown)
    sys.exit(0)


def run_dbt_upload(manifest_path, endpoint=None, key=None, tenant=None, as_json=False):
    from veraxi.cli.http_client import api_request

    try:
        manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"Error: manifest file not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Error: invalid manifest JSON in {manifest_path}: {exc}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("nodes"), dict):
        print("Error: manifest must be a dbt manifest object with a 'nodes' mapping", file=sys.stderr)
        sys.exit(1)
    data = api_request("POST", "/api/v1/dbt/ingest", body={"manifest": manifest},
                       endpoint=endpoint, key=key, tenant=tenant)
    if as_json:
        print(json.dumps(data, indent=2))
    else:
        print(f"dbt ingest: {json.dumps(data)}")
    sys.exit(0)


def run_dbt_lineage(target, endpoint=None, key=None, tenant=None, as_json=False):
    from veraxi.cli.http_client import api_request

    data = api_request("GET", "/api/v1/dbt/datasets", endpoint=endpoint, key=key,
                       tenant=tenant, params={"q": target})
    if as_json:
        print(json.dumps(data, indent=2))
        sys.exit(0)
    matches = data.get("matches") or []
    if not matches:
        print(f"No datasets matched '{target}'.")
        sys.exit(0)
    for match in matches:
        name = match.get("name") or match.get("unique_id")
        by = ", ".join(match.get("matched_by") or [])
        print(f"{name} (matched by: {by})")
        for direction in ("upstream", "downstream"):
            for node in match.get(direction) or []:
                print(f"  {direction}: {node.get('name') or node.get('unique_id')}")
    sys.exit(0)
