"""Published artifact endpoints — publish, unpublish, and the public page.

Backs the Flutter artifact panel's Share/publish flow (Claude-style):
a signed-in user publishes a code or renderable artifact, gets back a
public ``/a/{id}`` URL anyone can open, and can unpublish it again.
Records live in Redis alongside the gateway's other state (thread
activities in routes/chat.py, attachment metadata in routes/files.py).

The module also hosts the artifact-work sync endpoints
(``/api/artifacts/work/{thread_id}``): the panel's per-artifact work
(version history, current version, published link) stored per tenant
in Redis so it syncs across devices the way chat history does.
Unlike publish, work sync is private per-tenant data, so every
tenant — guests included — may use it.
"""

import html
import json
import logging
import re
import uuid
from datetime import UTC, datetime

import sentry_sdk
from fastapi import Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)

# get_tenant_id (backend/api_gateway.py) resolves unauthenticated
# "guest" requests — an x-guest header or ?guest=true with no
# credentials — to this identity. Guests may chat with their own API
# key, but publishing requires a real signed-in account, so the
# publish/delete endpoints reject it with 401.
GUEST_TENANT_ID = "local_guest"

ARTIFACT_KEY_PREFIX = "published_artifact:"
MAX_CODE_CHARS = 200_000
MAX_TITLE_CHARS = 300
VALID_ARTIFACT_KINDS = {"html", "svg", "mermaid", "react", "markdown", "code"}

# Artifact-work sync limits: a state holds at most this many versions,
# each at most MAX_CODE_CHARS long, and the whole serialized state
# must stay under the total cap (413, like oversize published code).
MAX_WORK_VERSIONS = 200
MAX_WORK_STATE_CHARS = 1_000_000

# Content-Security-Policy for the public artifact page. A srcdoc
# iframe's document has no URL of its own and *inherits the embedding
# page's CSP*, so this single policy governs both documents:
# - The outer page ships no scripts of its own and needs none; the
#   script-src allowance exists solely for the inherited inner
#   document, whose builders run inline bootstrap code
#   ('unsafe-inline') and load Babel, Mermaid, and marked from the CDN
#   hosts below, resolve npm imports through esm.sh (script-src for
#   the module loads, connect-src for its fetches), and pull in the
#   Tailwind Play CDN.
# - frame-src must explicitly allow the srcdoc frame ('self'/about:)
#   because default-src 'none' would otherwise block the frame itself.
# - img-src/style-src cover artifact content (inline styles throughout
#   the builders, data:/remote images); everything else falls back to
#   'none'.
PUBLIC_PAGE_CSP = (
    "default-src 'none'; "
    "script-src 'unsafe-inline' https://unpkg.com https://cdn.jsdelivr.net "
    "https://esm.sh https://cdn.tailwindcss.com; "
    "connect-src https://esm.sh; "
    "img-src data: https:; "
    "style-src 'unsafe-inline'; "
    "font-src data: https:; "
    "frame-src 'self' about:; "
    "base-uri 'none'; "
    "form-action 'none'"
)


class PublishArtifactRequest(BaseModel):
    """Body of POST /api/artifacts/publish.

    ``kind`` is classified client-side (html/svg/mermaid/react/
    markdown/code); anything else is stored as ``code``. When ``id``
    names an existing artifact owned by the caller, the publish
    overwrites it in place (same public URL); otherwise a fresh id is
    minted server-side.
    """

    title: str = ""
    file_name: str = ""
    language: str = ""
    code: str = ""
    kind: str = "code"
    id: str | None = None


# ---------------------------------------------------------------------------
# Storage seam + record helpers
# ---------------------------------------------------------------------------


def _get_store(request: Request):
    """Return the Redis client published artifacts are stored in.

    Mirrors how routes/chat.py and routes/files.py reach Redis through
    ``request.app.state.redis`` (the gateway lifespan pool). Kept as a
    module-level seam so tests can substitute an in-memory fake without
    a live Redis.
    """
    return request.app.state.redis


def _artifact_key(artifact_id: str) -> str:
    return f"{ARTIFACT_KEY_PREFIX}{artifact_id}"


def _work_key(tenant_id: str, thread_id: str) -> str:
    """Redis hash holding one thread's synced artifact work for a
    tenant, keyed like the tenant's other chat state (routes/chat.py
    uses ``tenant:{tenant_id}:thread_titles`` and friends). Fields
    are ``"{message_index}:{artifact_index}"``."""
    return f"tenant:{tenant_id}:artifact_work:{thread_id}"


def _decode(raw) -> str | None:
    if raw is None:
        return None
    if isinstance(raw, bytes):
        return raw.decode("utf-8")
    return raw


async def _load_artifact(store, artifact_id: str) -> dict | None:
    raw = _decode(await store.get(_artifact_key(artifact_id)))
    if raw is None:
        return None
    try:
        record = json.loads(raw)
    except (TypeError, ValueError):
        logger.warning("Corrupt published artifact record for id %s", artifact_id)
        return None
    return record if isinstance(record, dict) else None


def _require_signed_in_tenant(tenant_id: str) -> None:
    if tenant_id == GUEST_TENANT_ID:
        raise HTTPException(
            status_code=401,
            detail="Publishing requires a signed-in account",
        )


def _normalize_kind(kind) -> str:
    return kind if kind in VALID_ARTIFACT_KINDS else "code"


def _parse_work_payload(body) -> tuple[int, int, dict]:
    """Validate a PUT /api/artifacts/work body and return
    ``(message_index, artifact_index, state)``.

    Parsed by hand rather than with a pydantic model so every
    validation failure is a 400 (a model would answer 422 for type
    errors). Only the shape is checked: ``state`` must be an object
    whose ``versions`` is a list of strings within the size limits;
    all other fields (``updatedAt``, …) are stored opaquely.
    """
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="request body must be an object")
    message_index = body.get("message_index")
    artifact_index = body.get("artifact_index")
    for name, value in (
        ("message_index", message_index),
        ("artifact_index", artifact_index),
    ):
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise HTTPException(
                status_code=400, detail=f"{name} must be an integer >= 0"
            )
    state = body.get("state")
    if not isinstance(state, dict):
        raise HTTPException(status_code=400, detail="state must be an object")
    versions = state.get("versions")
    if (
        not isinstance(versions, list)
        or len(versions) > MAX_WORK_VERSIONS
        or any(
            not isinstance(version, str) or len(version) > MAX_CODE_CHARS
            for version in versions
        )
    ):
        raise HTTPException(
            status_code=400,
            detail=(
                f"state.versions must be a list of at most {MAX_WORK_VERSIONS} "
                f"strings, each at most {MAX_CODE_CHARS} characters"
            ),
        )
    if len(json.dumps(state)) > MAX_WORK_STATE_CHARS:
        raise HTTPException(
            status_code=413,
            detail=f"state too large (max {MAX_WORK_STATE_CHARS} characters)",
        )
    return message_index, artifact_index, state


# ---------------------------------------------------------------------------
# React source preparation — Python port of prepareReactArtifact in
# app/lib/features/chat/views/widgets/artifact_html_documents.dart.
# Keep the two in step: same import handling, same import map, same
# auto-mount snippet.
# ---------------------------------------------------------------------------

_IMPORT_STATEMENT_PATTERN = re.compile(
    r"""import\s+(?:([\s\S]*?)\s+from\s+)?['"]([^'"]+)['"];?"""
)
_DEFAULT_DECL_PATTERN = re.compile(
    r"export\s+default\s+(function|class)\s+([A-Za-z_$][\w$]*)"
)
_DEFAULT_NAME_PATTERN = re.compile(
    r"export\s+default\s+([A-Za-z_$][\w$]*)\s*;?\s*(?=\n|$)"
)
_EXPORT_PREFIX_PATTERN = re.compile(
    r"export\s+(?=(?:function|const|let|var|class)\s)"
)
_MANUAL_HOOKS_PATTERN = re.compile(r"(?:const|let|var)\s*\{([^}]*)\}\s*=\s*React\b")
_BRACES_PATTERN = re.compile(r"\{([\s\S]*)\}")

# Packages the React document's import map pins to esm.sh builds (see
# _REACT_IMPORT_MAP). Imports of these — and of their subpaths — stay
# exactly as written; the map resolves them.
_IMPORT_MAPPED_PACKAGES = {"react", "react-dom", "recharts", "lodash", "lucide-react"}

_HOOK_NAMES = [
    "useState",
    "useEffect",
    "useRef",
    "useMemo",
    "useCallback",
    "useContext",
    "useReducer",
]


def _is_import_mapped(specifier: str) -> bool:
    return any(
        specifier == pkg or specifier.startswith(pkg + "/")
        for pkg in _IMPORT_MAPPED_PACKAGES
    )


def _esm_url_for(specifier: str) -> str:
    # `external=react,react-dom` keeps the package on the import map's
    # single React copy — a second React instance would break hooks.
    return f"https://esm.sh/{specifier}?external=react,react-dom"


def _named_bindings(clause: str | None) -> set[str]:
    """Local names bound by an import clause's ``{ … }`` section,
    resolving ``name as alias`` to the alias (the name code uses)."""
    if clause is None:
        return set()
    braces = _BRACES_PATTERN.search(clause)
    if braces is None:
        return set()
    bindings = set()
    for part in braces.group(1).split(","):
        part = part.strip()
        if not part:
            continue
        if " as " in part:
            bindings.add(part.split(" as ")[-1].strip())
        else:
            bindings.add(part.replace("type ", "", 1).strip())
    return bindings


def prepare_react_artifact(source: str) -> str:
    """Prepare React/JSX source to run as an ES module in the harness
    document, the way modern in-browser runners (import maps + esm.sh)
    do it:

    - Imports of ``react``, ``react-dom``, and the curated packages
      (recharts, lodash, lucide-react) — including subpaths — stay as
      written; the document's import map resolves them to pinned
      esm.sh builds that share one React copy.
    - Any other bare import is rewritten to its esm.sh URL with
      ``external=react,react-dom``, so arbitrary npm packages resolve
      too. Relative imports and stylesheet imports are dropped — a
      single-file frame has no sibling files.
    - ``export default function App …`` keeps the declaration and
      records ``App``; ``export default App;`` records ``App``; any
      other default export becomes ``const __VeraxiDefaultComponent``.
    - Remaining ``export`` prefixes on declarations are stripped.
    - Hooks the code uses but never imports (nor destructures from a
      React binding) get an ``import { … } from 'react'`` line.
    - ``</script>`` inside the source is escaped to ``<\\/script>`` so
      it cannot terminate the embedding script element early.
    - Unless the source mounts itself, a snippet is appended that
      mounts the default export — or a component named App / Component
      / Demo / Main — into ``#root`` with React 18's ``createRoot``.
    """
    imported_from_react: set[str] = set()

    def _rewrite_import(match: re.Match[str]) -> str:
        clause = match.group(1)
        specifier = match.group(2)
        if specifier.endswith(".css"):
            return ""
        if specifier.startswith((".", "/")):
            return ""
        if specifier == "react":
            imported_from_react.update(_named_bindings(clause))
            return match.group(0)
        if _is_import_mapped(specifier):
            return match.group(0)
        url = _esm_url_for(specifier)
        if clause is None:
            return f"import '{url}';"
        return f"import {clause} from '{url}';"

    code = _IMPORT_STATEMENT_PATTERN.sub(_rewrite_import, source)

    component_name: str | None = None
    decl = _DEFAULT_DECL_PATTERN.search(code)
    if decl is not None:
        # `export default function App …` — keep the declaration, drop
        # the export prefix, remember the name.
        component_name = decl.group(2)
        code = _DEFAULT_DECL_PATTERN.sub(
            lambda m: f"{m.group(1)} {m.group(2)}", code
        )
    elif _DEFAULT_NAME_PATTERN.search(code) is not None:
        # `export default App;` as a standalone statement — remember
        # the name and drop the statement.
        component_name = _DEFAULT_NAME_PATTERN.search(code).group(1)  # type: ignore[union-attr]
        code = _DEFAULT_NAME_PATTERN.sub("", code)
    elif "export default" in code:
        # Any other default export is an expression (anonymous
        # component, arrow function, …): bind it to a constant we can
        # mount.
        component_name = "__VeraxiDefaultComponent"
        code = re.sub(
            r"export\s+default\s+",
            "const __VeraxiDefaultComponent = ",
            code,
            count=1,
        )

    code = _EXPORT_PREFIX_PATTERN.sub("", code)

    manually_bound: set[str] = set()
    for match in _MANUAL_HOOKS_PATTERN.finditer(code):
        manually_bound.update(_named_bindings("{" + match.group(1) + "}"))
    missing_hooks = [
        name
        for name in _HOOK_NAMES
        if name in code
        and name not in imported_from_react
        and name not in manually_bound
    ]
    if missing_hooks:
        code = f"import {{ {', '.join(missing_hooks)} }} from 'react';\n" + code

    should_auto_mount = "createRoot" not in code and "ReactDOM.render" not in code

    if should_auto_mount:
        candidates = [
            *([component_name] if component_name is not None else []),
            "App",
            "Component",
            "Demo",
            "Main",
        ]
        checks = " || ".join(
            f"(typeof {name} !== 'undefined' && {name})" for name in candidates
        )
        code = (
            "import __VeraxiReact from 'react';\n"
            "import { createRoot as __VeraxiCreateRoot } from 'react-dom/client';\n"
            + code
            + "\n;(function () {\n"
            + f"  var __VeraxiComponent = {checks} || null;\n"
            + "  var __VeraxiRootEl = document.getElementById('root');\n"
            + "  if (__VeraxiComponent) {\n"
            + "    __VeraxiCreateRoot(__VeraxiRootEl).render(\n"
            + "      __VeraxiReact.createElement(__VeraxiComponent)\n"
            + "    );\n"
            + "  } else {\n"
            + "    __VeraxiRootEl.innerHTML =\n"
            + "      '<pre style=\"color:#FCA5A5;white-space:pre-wrap\">No component found. ' +\n"
            + "      'Export a component by default, or name it App.</pre>';\n"
            + "  }\n"
            + "})();\n"
        )

    # Escape after all transforms: a literal closing script tag
    # anywhere in the source (string, JSX text, comment) would
    # otherwise end the embedding <script type="text/plain"> element
    # early and break out.
    return code.replace("</script", "<\\/script")


# The import map for the React harness document: React 18 and the
# curated library set pinned to free esm.sh builds. The `?external`
# pins keep every package on this one React copy (a second copy breaks
# hooks); the trailing-slash entries cover subpath imports
# (`react/jsx-runtime`, `lodash/debounce`, …).
_REACT_IMPORT_MAP = """
{
  "imports": {
    "react": "https://esm.sh/react@18.3.1",
    "react/": "https://esm.sh/react@18.3.1/",
    "react-dom": "https://esm.sh/react-dom@18.3.1",
    "react-dom/": "https://esm.sh/react-dom@18.3.1/",
    "recharts": "https://esm.sh/recharts@2.15.0?external=react,react-dom&bundle",
    "lodash": "https://esm.sh/lodash@4.17.21",
    "lucide-react": "https://esm.sh/lucide-react@0.469.0?external=react,react-dom&bundle"
  }
}
"""


# ---------------------------------------------------------------------------
# Inner document builders — server-side counterparts of the Dart
# builders in artifact_html_documents.dart. The public page runs the
# result inside a sandboxed srcdoc iframe, so the documents are built
# to the same recipe (same CDNs, same base styles). One difference:
# markdown renders natively in the app, so here it is rendered in the
# frame with the marked CDN; plain `code` gets a minimal dark page.
# ---------------------------------------------------------------------------

_BASE_STYLES = """    body {
      margin: 0;
      padding: 16px;
      background: #141416;
      color: #E2E8F0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
"""


def _build_html_document(code: str) -> str:
    # A full document (the author wrote <!DOCTYPE html> / <html>) is
    # already self-contained; wrapping it would nest documents.
    if "<html" in code.lower():
        return code
    return (
        "<!DOCTYPE html>\n"
        "<html>\n"
        "<head>\n"
        '  <meta charset="utf-8">\n'
        '  <meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
        '  <script src="https://cdn.tailwindcss.com"></script>\n'
        "  <style>\n"
        + _BASE_STYLES
        + "  </style>\n"
        "</head>\n"
        "<body>\n"
        + code
        + "\n</body>\n"
        "</html>\n"
    )


def _build_svg_document(code: str) -> str:
    return (
        "<!DOCTYPE html>\n"
        "<html>\n"
        "<head>\n"
        '  <meta charset="utf-8">\n'
        '  <meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
        "  <style>\n"
        "    body {\n"
        "      margin: 0;\n"
        "      padding: 24px;\n"
        "      background: #141416;\n"
        "      color: #E2E8F0;\n"
        "      display: flex;\n"
        "      justify-content: center;\n"
        "      align-items: flex-start;\n"
        "      min-height: 85vh;\n"
        "      box-sizing: border-box;\n"
        "    }\n"
        "    svg { max-width: 100%; height: auto; }\n"
        "  </style>\n"
        "</head>\n"
        "<body>\n"
        + code
        + "\n</body>\n"
        "</html>\n"
    )


def _build_mermaid_document(code: str) -> str:
    escaped_code = html.escape(code, quote=False)
    return (
        "<!DOCTYPE html>\n"
        "<html>\n"
        "<head>\n"
        '  <meta charset="utf-8">\n'
        '  <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>\n'
        "  <style>\n"
        "    body {\n"
        "      margin: 0;\n"
        "      padding: 24px;\n"
        "      background: #141416;\n"
        "      color: #E2E8F0;\n"
        "      display: flex;\n"
        "      justify-content: center;\n"
        "      align-items: center;\n"
        "      min-height: 85vh;\n"
        '      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;\n'
        "    }\n"
        "    .mermaid {\n"
        "      display: flex;\n"
        "      justify-content: center;\n"
        "      width: 100%;\n"
        "    }\n"
        "  </style>\n"
        "</head>\n"
        "<body>\n"
        '  <pre class="mermaid">\n'
        + escaped_code
        + "\n  </pre>\n"
        "  <script>\n"
        "    mermaid.initialize({\n"
        "      startOnLoad: true,\n"
        "      theme: 'dark',\n"
        "      securityLevel: 'loose'\n"
        "    });\n"
        "  </script>\n"
        "</body>\n"
        "</html>\n"
    )


_REACT_BOOTSTRAP = """  <script>
    (function () {
      function showError(err) {
        document.getElementById('root').innerHTML =
          '<pre style="color:#FCA5A5;white-space:pre-wrap"></pre>';
        document.querySelector('#root pre').textContent =
          'Preview error: ' + (err && err.message ? err.message : err);
      }
      try {
        var src = document.getElementById('veraxi-react-source').textContent;
        var out = Babel.transform(src, {
          sourceType: 'module',
          presets: [
            'react',
            ['typescript', { isTSX: true, allExtensions: true }]
          ]
        }).code;
        var script = document.createElement('script');
        script.type = 'module';
        script.textContent = out;
        script.onerror = function () {
          showError('Failed to load a module — an import could not be ' +
            'resolved (unknown package or no network).');
        };
        document.body.appendChild(script);
      } catch (err) {
        showError(err);
      }
    })();
  </script>
"""


def _build_react_document(source: str) -> str:
    prepared = prepare_react_artifact(source)
    return (
        "<!DOCTYPE html>\n"
        "<html>\n"
        "<head>\n"
        '  <meta charset="utf-8">\n'
        '  <meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
        '  <script src="https://cdn.tailwindcss.com"></script>\n'
        '  <script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>\n'
        '  <script type="importmap">\n'
        + _REACT_IMPORT_MAP
        + "  </script>\n"
        "  <style>\n"
        "    body {\n"
        "      margin: 0;\n"
        "      padding: 16px;\n"
        "      background: #141416;\n"
        "      color: #E2E8F0;\n"
        '      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;\n'
        "    }\n"
        "  </style>\n"
        "</head>\n"
        "<body>\n"
        '  <div id="root"></div>\n'
        '  <script type="text/plain" id="veraxi-react-source">\n'
        + prepared
        + "\n  </script>\n"
        + _REACT_BOOTSTRAP
        + "</body>\n"
        "</html>\n"
    )


def _build_markdown_document(code: str) -> str:
    # The source travels as an embedded JSON string; escaping "</"
    # keeps a literal "</script>" in the markdown from ending the
    # embedding script element early.
    source_json = json.dumps(code).replace("</", "<\\/")
    return (
        "<!DOCTYPE html>\n"
        "<html>\n"
        "<head>\n"
        '  <meta charset="utf-8">\n'
        '  <meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
        '  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>\n'
        "  <style>\n"
        + _BASE_STYLES
        + "    pre { background: #1F2430; padding: 12px; overflow-x: auto; }\n"
        + "    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }\n"
        + "    a { color: #93C5FD; }\n"
        + "  </style>\n"
        "</head>\n"
        "<body>\n"
        '  <div id="content"></div>\n'
        "  <script>\n"
        + f"    var source = {source_json};\n"
        + "    document.getElementById('content').innerHTML = marked.parse(source);\n"
        "  </script>\n"
        "</body>\n"
        "</html>\n"
    )


def _build_code_document(code: str) -> str:
    return (
        "<!DOCTYPE html>\n"
        "<html>\n"
        "<head>\n"
        '  <meta charset="utf-8">\n'
        '  <meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
        "  <style>\n"
        + _BASE_STYLES
        + "    pre { margin: 0; white-space: pre-wrap; word-break: break-word; }\n"
        + "    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }\n"
        + "  </style>\n"
        "</head>\n"
        "<body>\n"
        + f"<pre><code>{html.escape(code)}</code></pre>\n"
        + "</body>\n"
        "</html>\n"
    )


def _build_artifact_document(kind: str, code: str) -> str:
    """Build the standalone inner document for a published artifact.
    Unknown kinds fall back to the HTML wrapper, like the Dart side."""
    if kind == "svg":
        return _build_svg_document(code)
    if kind == "mermaid":
        return _build_mermaid_document(code)
    if kind == "react":
        return _build_react_document(code)
    if kind == "markdown":
        return _build_markdown_document(code)
    if kind == "code":
        return _build_code_document(code)
    return _build_html_document(code)


def _render_public_page(artifact: dict) -> str:
    title = str(
        artifact.get("title") or artifact.get("file_name") or "Untitled artifact"
    )
    meta = " · ".join(
        part
        for part in [artifact.get("file_name") or "", artifact.get("language") or ""]
        if part
    )
    inner_document = _build_artifact_document(
        _normalize_kind(artifact.get("kind")), artifact.get("code") or ""
    )
    # The artifact runs in a sandboxed srcdoc iframe: allow-scripts
    # only (no allow-same-origin), so it executes in an opaque origin
    # with no access to this page, its cookies, or its storage. The
    # srcdoc value is attribute-escaped so the inner document cannot
    # break out of the attribute and inject markup into this page.
    return (
        "<!DOCTYPE html>\n"
        "<html>\n"
        "<head>\n"
        '  <meta charset="utf-8">\n'
        '  <meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
        f"  <title>{html.escape(title)}</title>\n"
        "  <style>\n"
        "    body { margin: 0; background: #0B0B0D; color: #E2E8F0; "
        'font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }\n'
        "    .banner { display: flex; flex-wrap: wrap; align-items: baseline; "
        "gap: 8px 16px; padding: 12px 16px; background: #141416; "
        "border-bottom: 1px solid #26262B; }\n"
        "    .banner-title { font-weight: 600; }\n"
        "    .banner-meta { color: #94A3B8; font-size: 13px; }\n"
        "    .banner-badge { margin-left: auto; color: #FBBF24; "
        "border: 1px solid #92600A; border-radius: 999px; "
        "padding: 2px 10px; font-size: 12px; }\n"
        "    iframe { display: block; width: 100%; height: calc(100vh - 53px); "
        "border: 0; background: #141416; }\n"
        "  </style>\n"
        "</head>\n"
        "<body>\n"
        '  <header class="banner">\n'
        f'    <span class="banner-title">{html.escape(title)}</span>\n'
        f'    <span class="banner-meta">{html.escape(meta)}</span>\n'
        '    <span class="banner-badge">Content is user-generated and unverified</span>\n'
        "  </header>\n"
        f'  <iframe sandbox="allow-scripts" srcdoc="{html.escape(inner_document, quote=True)}"></iframe>\n'
        "</body>\n"
        "</html>\n"
    )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


def register_artifact_routes(
    app_router, get_tenant_id, verify_infrastructure_access, limiter, config
):
    """Register all published-artifact routes with injected auth dependencies."""

    @app_router.post("/api/artifacts/publish")
    @limiter.limit(config.rate_limit_ingest)
    async def publish_artifact(
        request: Request,
        payload: PublishArtifactRequest,
        tenant_id: str = Depends(get_tenant_id),
    ):
        _require_signed_in_tenant(tenant_id)
        if not payload.code:
            raise HTTPException(status_code=400, detail="code is required")
        if len(payload.code) > MAX_CODE_CHARS:
            raise HTTPException(
                status_code=413,
                detail=f"code too large (max {MAX_CODE_CHARS} characters)",
            )
        if len(payload.title) > MAX_TITLE_CHARS:
            raise HTTPException(
                status_code=400,
                detail=f"title too long (max {MAX_TITLE_CHARS} characters)",
            )
        try:
            store = _get_store(request)
            now = datetime.now(UTC).isoformat()
            existing = None
            if payload.id:
                existing = await _load_artifact(store, payload.id)
                if existing is not None and existing.get("tenant_id") != tenant_id:
                    # Don't leak that the id exists under another tenant.
                    raise HTTPException(
                        status_code=404, detail="Artifact not found"
                    )
            if existing is not None:
                artifact_id = payload.id
                created_at = existing.get("created_at") or now
            else:
                artifact_id = uuid.uuid4().hex
                created_at = now
            record = {
                "id": artifact_id,
                "tenant_id": tenant_id,
                "title": payload.title,
                "file_name": payload.file_name,
                "language": payload.language,
                "code": payload.code,
                "kind": _normalize_kind(payload.kind),
                "created_at": created_at,
                "updated_at": now,
            }
            await store.set(_artifact_key(artifact_id), json.dumps(record))
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Error publishing artifact: {e}")
            raise HTTPException(status_code=500, detail=str(e))
        # The gateway runs behind ProxyHeadersMiddleware with
        # trusted_hosts="*", so request.base_url reflects the public
        # host and the returned URL is directly shareable.
        url = f"{request.base_url}a/{artifact_id}"
        return {"id": artifact_id, "url": url}

    @app_router.delete("/api/artifacts/{artifact_id}")
    async def delete_artifact(
        artifact_id: str,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        _require_signed_in_tenant(tenant_id)
        try:
            store = _get_store(request)
            existing = await _load_artifact(store, artifact_id)
            if existing is None or existing.get("tenant_id") != tenant_id:
                # Missing and not-owned look identical: don't leak
                # existence.
                raise HTTPException(status_code=404, detail="Artifact not found")
            await store.delete(_artifact_key(artifact_id))
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Error deleting artifact: {e}")
            raise HTTPException(status_code=500, detail=str(e))
        return {"deleted": True}

    @app_router.put("/api/artifacts/work/{thread_id}")
    @limiter.limit(config.rate_limit_ingest)
    async def put_artifact_work(
        thread_id: str,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        # No _require_signed_in_tenant here: work sync is private
        # per-tenant data, and chat history already works for the
        # guest identity the same way, so every tenant may sync.
        try:
            body = await request.json()
        except Exception:
            raise HTTPException(
                status_code=400, detail="request body must be valid JSON"
            )
        message_index, artifact_index, state = _parse_work_payload(body)
        try:
            store = _get_store(request)
            await store.hset(
                _work_key(tenant_id, thread_id),
                f"{message_index}:{artifact_index}",
                json.dumps(state),
            )
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Error saving artifact work: {e}")
            raise HTTPException(status_code=500, detail=str(e))
        return {"saved": True}

    @app_router.get("/api/artifacts/work/{thread_id}")
    async def get_artifact_work(
        thread_id: str,
        request: Request,
        tenant_id: str = Depends(get_tenant_id),
    ):
        try:
            store = _get_store(request)
            raw_entries = await store.hgetall(_work_key(tenant_id, thread_id))
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Error loading artifact work: {e}")
            raise HTTPException(status_code=500, detail=str(e))
        entries = {}
        for raw_field, raw_value in (raw_entries or {}).items():
            field = _decode(raw_field)
            try:
                entries[field] = json.loads(_decode(raw_value))
            except (TypeError, ValueError) as e:
                # A corrupt entry is skipped, not fatal: the rest of
                # the thread's work still syncs.
                sentry_sdk.capture_exception(e)
                logger.warning(
                    "Corrupt artifact work entry %s in thread %s", field, thread_id
                )
        return {"entries": entries}

    @app_router.get("/a/{artifact_id}")
    async def get_public_artifact(artifact_id: str, request: Request):
        artifact = await _load_artifact(_get_store(request), artifact_id)
        if artifact is None:
            raise HTTPException(status_code=404, detail="Artifact not found")
        return HTMLResponse(
            content=_render_public_page(artifact),
            headers={
                "X-Content-Type-Options": "nosniff",
                "Referrer-Policy": "no-referrer",
                "Content-Security-Policy": PUBLIC_PAGE_CSP,
            },
        )
