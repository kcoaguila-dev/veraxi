"""Shared stdlib HTTP client for Veraxi CLI API commands.

Extracted when the second HTTP caller appeared (chat pre-flight in
WP5, after evals --remote in WP1). Handles base URL (strips /sse),
Bearer auth, JSON bodies/query params, timeouts, and readable errors:
4xx/5xx -> stderr + SystemExit(1). Never prints the API key.
"""

import gzip
import json
import sys
import urllib.error
import urllib.parse
import urllib.request


def base_url(endpoint):
    base = (endpoint or "https://api.veraxi.me/sse").rstrip("/")
    return base.removesuffix("/sse")


def api_request(method, path, body=None, endpoint=None, key=None, tenant=None, params=None, timeout=30, quiet=False, gzip_body=False):
    """Call the Veraxi HTTP API and return the parsed JSON dict.

    On HTTP or network error, prints a readable message to stderr and
    raises SystemExit(1).
    """
    url = f"{base_url(endpoint)}{path}"
    if params:
        clean = {k: v for k, v in params.items() if v is not None}
        if clean:
            url = f"{url}?{urllib.parse.urlencode(clean)}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
        if gzip_body:
            # Opt-in request compression (stdlib gzip): used for large
            # SCIP uploads; the backend decompresses when it sees the
            # Content-Encoding header.
            data = gzip.compress(data)
            headers["Content-Encoding"] = "gzip"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    if key:
        req.add_header("Authorization", f"Bearer {key}")
    if tenant:
        req.add_header("X-Tenant-Id", tenant)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", errors="replace")
        except Exception:
            detail = ""
        # Surface the server's detail message verbatim when it is JSON.
        message = detail
        try:
            parsed = json.loads(detail)
        except Exception:
            parsed = None
        if isinstance(parsed, dict) and parsed.get("detail"):
            message = str(parsed["detail"])
        if quiet:
            raise RuntimeError(f"API returned {exc.code}: {message}") from exc
        print(f"Error: API returned {exc.code}: {message}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        if quiet:
            raise
        print(f"Error: request to {path} failed: {exc}", file=sys.stderr)
        sys.exit(1)
