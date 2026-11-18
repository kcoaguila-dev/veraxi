"""User memories CLI (WP4) — the memory store going forward.

Backed by Supabase `user_memories` via backend/routes/memories.py
(services/memory_store.py): per-user memories with temporal validity
(`valid_to`; expire soft-expires and keeps the row, delete removes it).

Memory-store unification: `user_memories` is the single source of
truth going forward. The legacy Neo4j-backed `veraxi memory` /
`veraxi remember` commands (project-scoped agent rules) are
deprecated; there is no data to migrate. No dual-write or bridge:
this command group writes Supabase only.
Routes:
- GET    /api/v1/memories?include_expired=
- POST   /api/v1/memories {content, source, valid_from?} (201)
- PUT    /api/v1/memories/{id} {content?, source?, valid_from?, valid_to?}
- POST   /api/v1/memories/{id}/expire
- DELETE /api/v1/memories/{id}
Exit codes: 0 ok, 1 error.
"""

import json
import sys


def _render_memory(row):
    valid_to = row.get("valid_to")
    suffix = f" valid_to={valid_to}" if valid_to else ""
    print(f"{row.get('id')} [{row.get('source')}] {row.get('content')}{suffix}")


def run_memories_list(endpoint=None, key=None, tenant=None, as_json=False, include_all=False):
    from veraxi.cli.http_client import api_request

    data = api_request("GET", "/api/v1/memories", endpoint=endpoint, key=key, tenant=tenant,
                       params={"include_expired": str(include_all).lower()})
    rows = data.get("memories") or []
    if not include_all:
        rows = [r for r in rows if not r.get("valid_to")]
    if as_json:
        print(json.dumps({"memories": rows}, indent=2))
        sys.exit(0)
    if not rows:
        print("No memories found.")
        print("Use 'veraxi memories add \"<content>\"' to record one.")
        sys.exit(0)
    for row in rows:
        _render_memory(row)
    sys.exit(0)


def run_memories_add(content, endpoint=None, key=None, tenant=None, as_json=False, source="manual"):
    from veraxi.cli.http_client import api_request

    if not content or not content.strip():
        print("Error: content must not be empty.", file=sys.stderr)
        sys.exit(1)
    data = api_request("POST", "/api/v1/memories", body={"content": content, "source": source},
                       endpoint=endpoint, key=key, tenant=tenant)
    if as_json:
        print(json.dumps(data, indent=2))
    else:
        _render_memory(data)
    sys.exit(0)


def run_memories_edit(memory_id, content=None, source=None, endpoint=None, key=None, tenant=None, as_json=False):
    from veraxi.cli.http_client import api_request

    body = {}
    if content is not None:
        body["content"] = content
    if source is not None:
        body["source"] = source
    if not body:
        print("Error: provide --content or --source to edit.", file=sys.stderr)
        sys.exit(1)
    data = api_request("PUT", f"/api/v1/memories/{memory_id}", body=body,
                       endpoint=endpoint, key=key, tenant=tenant)
    if as_json:
        print(json.dumps(data, indent=2))
    else:
        _render_memory(data)
    sys.exit(0)


def run_memories_expire(memory_id, endpoint=None, key=None, tenant=None, as_json=False):
    from veraxi.cli.http_client import api_request

    data = api_request("POST", f"/api/v1/memories/{memory_id}/expire", body={},
                       endpoint=endpoint, key=key, tenant=tenant)
    if as_json:
        print(json.dumps(data, indent=2))
    else:
        print(f"Expired {data.get('id')} (valid_to={data.get('valid_to')}; row retained)")
    sys.exit(0)


def run_memories_delete(memory_id, endpoint=None, key=None, tenant=None, as_json=False):
    from veraxi.cli.http_client import api_request

    data = api_request("DELETE", f"/api/v1/memories/{memory_id}",
                       endpoint=endpoint, key=key, tenant=tenant)
    if as_json:
        print(json.dumps(data, indent=2))
    else:
        print(f"Deleted {data.get('id', memory_id)}")
    sys.exit(0)


def run_memories_stats(endpoint=None, key=None, tenant=None, as_json=False):
    from veraxi.cli.http_client import api_request

    data = api_request("GET", "/api/v1/memories", endpoint=endpoint, key=key, tenant=tenant,
                       params={"include_expired": "true"})
    rows = data.get("memories") or []
    active = sum(1 for r in rows if not r.get("valid_to"))
    expired = len(rows) - active
    by_source: dict[str, int] = {}
    for r in rows:
        src = r.get("source") or "manual"
        by_source[src] = by_source.get(src, 0) + 1
    summary = {
        "storage": "user_memories",
        "total": len(rows),
        "active": active,
        "expired": expired,
        "by_source": by_source,
    }
    if as_json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"Memories (user_memories): total={len(rows)} active={active} expired={expired}")
        if by_source:
            sources_str = ", ".join(f"{k}={v}" for k, v in sorted(by_source.items()))
            print(f"Sources: {sources_str}")
    sys.exit(0)
