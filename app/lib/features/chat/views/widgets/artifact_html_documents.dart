/// Builds the standalone HTML documents that artifact previews run in.
///
/// This is the same recipe Claude's artifact pane uses: the content is
/// placed in a self-contained document which the caller runs inside a
/// sandboxed frame (an `<iframe sandbox="allow-scripts" srcdoc>` on web,
/// a WebView on native), so its scripts execute in an opaque origin with
/// no access to the host app, its cookies, or its storage.
///
/// - HTML runs as authored (fragments are wrapped in a base document
///   with the Tailwind Play CDN available; full documents pass
///   through untouched).
/// - SVG markup is centered on the artifact background.
/// - Mermaid source is rendered by the Mermaid CDN script.
/// - React/JSX is transpiled in the frame by Babel standalone and run
///   as an ES module: an import map pins React 18 and a curated set
///   of libraries (recharts, lodash, lucide-react) to free esm.sh
///   builds that share the one React copy, any other bare import is
///   rewritten to its esm.sh URL, and the top-level component is
///   auto-mounted to `#root` — no build step, no paid service,
///   exactly like Claude's React artifacts.
///
/// Pure Dart on purpose: both platform sandbox implementations share
/// these builders so the documents cannot drift apart, and the React
/// source preparation is unit-testable without a browser.
library;

import 'dart:convert';

/// Dispatches to the document builder for [kind]
/// (`html`, `svg`, `mermaid`, `react`). Unknown kinds fall back to the
/// HTML wrapper.
String buildArtifactDocument(
  String kind,
  String code, {
  Map<String, String> siblingFiles = const {},
}) {
  return switch (kind) {
    'svg' => buildSvgArtifactDocument(code),
    'mermaid' => buildMermaidArtifactDocument(code),
    'react' => buildReactArtifactDocument(code, siblingFiles: siblingFiles),
    _ => buildHtmlArtifactDocument(code),
  };
}

/// JS shim injected into every artifact document: a promise-based
/// `window.veraxiStorage` (aliased as `window.storage`) key-value
/// API proxied over postMessage to the host app, because the
/// sandboxed iframe's opaque origin has no usable localStorage.
/// The host validates every request and replies with
/// `{type: 'veraxi_storage_reply', requestId, ok, data, error}`.
/// On native, replies arrive via `window.__veraxiStorageReply(...)`
/// called by the WebView host; requests go out over the
/// `VeraxiStorage` JavaScript channel when present, else the
/// `VeraxiRunner` channel, else `window.parent.postMessage`.
const String veraxiStorageShimScript = '''
<script>
(function () {
  var pending = {};
  var counter = 0;
  function settle(reply) {
    if (!reply || reply.type !== 'veraxi_storage_reply') return;
    var entry = pending[reply.requestId];
    if (!entry) return;
    delete pending[reply.requestId];
    if (reply.ok) entry.resolve(reply.data);
    else entry.reject(new Error(reply.error || 'storage error'));
  }
  window.__veraxiStorageReply = settle;
  window.addEventListener('message', function (event) {
    var data = event.data;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (e) { return; }
    }
    settle(data);
  });
  function send(op, key, value) {
    return new Promise(function (resolve, reject) {
      var requestId = 'vs_' + (++counter) + '_' + Date.now();
      pending[requestId] = { resolve: resolve, reject: reject };
      var msg = { type: 'veraxi_storage', requestId: requestId, op: op,
                  key: key || null, value: value === undefined ? null : value };
      var raw = JSON.stringify(msg);
      setTimeout(function () {
        if (pending[requestId]) {
          delete pending[requestId];
          reject(new Error('veraxiStorage: host did not reply'));
        }
      }, 10000);
      if (typeof VeraxiStorage !== 'undefined' && VeraxiStorage.postMessage) {
        VeraxiStorage.postMessage(raw);
      } else if (typeof VeraxiRunner !== 'undefined' && VeraxiRunner.postMessage) {
        VeraxiRunner.postMessage(raw);
      } else {
        window.parent.postMessage(raw, '*');
      }
    });
  }
  var api = {
    get: function (key) { return send('get', key); },
    set: function (key, value) { return send('set', key, String(value)); },
    delete: function (key) { return send('delete', key); },
    list: function (prefix) { return send('list', prefix || ''); }
  };
  window.veraxiStorage = api;
  window.storage = api;
})();
</script>
''';

/// Inserts the storage shim into a full HTML document the author
/// wrote, just before `</head>` (or `</body>` when there is no head).
String injectVeraxiStorageShim(String document) {
  if (document.contains('window.veraxiStorage')) return document;
  final headEnd = document.toLowerCase().indexOf('</head>');
  if (headEnd >= 0) {
    return document.replaceRange(headEnd, headEnd, veraxiStorageShimScript);
  }
  final bodyEnd = document.toLowerCase().indexOf('</body>');
  if (bodyEnd >= 0) {
    return document.replaceRange(bodyEnd, bodyEnd, veraxiStorageShimScript);
  }
  return '$document\n$veraxiStorageShimScript';
}

/// JS shim injected into HTML and React artifact documents:
/// `window.veraxi.complete(prompt, opts?)` (aliased as
/// `window.claude.complete` for artifacts written against Claude's
/// API) proxied over the same bridge transports as the storage
/// shim, because the sandboxed frame must never hold an API key —
/// the host app makes the authenticated call and posts the text
/// back. The host validates every request and replies with
/// `{type: 'veraxi_complete_reply', requestId, ok, text, error}`.
/// On native, replies arrive via `window.__veraxiCompleteReply(...)`
/// called by the WebView host; requests go out over the `VeraxiAi`
/// JavaScript channel when present, else the `VeraxiRunner`
/// channel, else `window.parent.postMessage`. The timeout is 60s:
/// a completion is an LLM call, not a storage read.
const String veraxiAiShimScript = '''
<script>
(function () {
  var pending = {};
  var counter = 0;
  function settle(reply) {
    if (!reply || reply.type !== 'veraxi_complete_reply') return;
    var entry = pending[reply.requestId];
    if (!entry) return;
    delete pending[reply.requestId];
    if (reply.ok) entry.resolve(reply.text);
    else entry.reject(new Error(reply.error || 'AI completion failed'));
  }
  window.__veraxiCompleteReply = settle;
  window.addEventListener('message', function (event) {
    var data = event.data;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (e) { return; }
    }
    settle(data);
  });
  function complete(prompt, opts) {
    return new Promise(function (resolve, reject) {
      var requestId = 'va_' + (++counter) + '_' + Date.now();
      pending[requestId] = { resolve: resolve, reject: reject };
      opts = opts || {};
      var msg = { type: 'veraxi_complete', requestId: requestId,
                  prompt: prompt,
                  system: opts.system || null,
                  model: opts.model || null,
                  maxTokens: opts.maxTokens || null };
      var raw = JSON.stringify(msg);
      setTimeout(function () {
        if (pending[requestId]) {
          delete pending[requestId];
          reject(new Error('veraxi.complete: host did not reply'));
        }
      }, 60000);
      if (typeof VeraxiAi !== 'undefined' && VeraxiAi.postMessage) {
        VeraxiAi.postMessage(raw);
      } else if (typeof VeraxiRunner !== 'undefined' && VeraxiRunner.postMessage) {
        VeraxiRunner.postMessage(raw);
      } else {
        window.parent.postMessage(raw, '*');
      }
    });
  }
  var veraxi = window.veraxi || {};
  veraxi.complete = complete;
  window.veraxi = veraxi;
  var claude = window.claude || {};
  claude.complete = complete;
  window.claude = claude;
})();
</script>
''';

/// Inserts the AI shim into a full HTML document the author wrote,
/// just before `</head>` (or `</body>` when there is no head).
String injectVeraxiAiShim(String document) {
  if (document.contains('veraxi_complete')) return document;
  final headEnd = document.toLowerCase().indexOf('</head>');
  if (headEnd >= 0) {
    return document.replaceRange(headEnd, headEnd, veraxiAiShimScript);
  }
  final bodyEnd = document.toLowerCase().indexOf('</body>');
  if (bodyEnd >= 0) {
    return document.replaceRange(bodyEnd, bodyEnd, veraxiAiShimScript);
  }
  return '$document\n$veraxiAiShimScript';
}

const String _baseStyles = '''
    body {
      margin: 0;
      padding: 16px;
      background: #141416;
      color: #E2E8F0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
''';

String buildHtmlArtifactDocument(String code) {
  // A full document (the assistant wrote <!DOCTYPE html> / <html>) is
  // already self-contained; wrapping it would nest documents. The
  // storage and AI shims are still injected so window.veraxiStorage
  // and window.veraxi.complete work.
  if (code.toLowerCase().contains('<html')) {
    return injectVeraxiAiShim(injectVeraxiStorageShim(code));
  }
  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script src="https://cdn.tailwindcss.com"></script>
$veraxiStorageShimScript$veraxiAiShimScript  <style>
$_baseStyles  </style>
</head>
<body>
$code
</body>
</html>
''';
}

String buildSvgArtifactDocument(String code) {
  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
$veraxiStorageShimScript  <style>
    body {
      margin: 0;
      padding: 24px;
      background: #141416;
      color: #E2E8F0;
      display: flex;
      justify-content: center;
      align-items: flex-start;
      min-height: 85vh;
      box-sizing: border-box;
    }
    svg { max-width: 100%; height: auto; }
  </style>
</head>
<body>
$code
</body>
</html>
''';
}

String buildMermaidArtifactDocument(String code) {
  final escapedCode = code
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
$veraxiStorageShimScript  <style>
    body {
      margin: 0;
      padding: 24px;
      background: #141416;
      color: #E2E8F0;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 85vh;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
    .mermaid {
      display: flex;
      justify-content: center;
      width: 100%;
    }
  </style>
</head>
<body>
  <pre class="mermaid">
$escapedCode
  </pre>
  <script>
    mermaid.initialize({
      startOnLoad: true,
      theme: 'dark',
      securityLevel: 'loose'
    });
  </script>
</body>
</html>
''';
}

/// The result of preparing React/JSX source for the in-frame harness.
class ReactArtifactPreparation {
  /// Source prepared to run as an ES module: imports resolved for the
  /// document's import map (see [buildReactArtifactDocument]),
  /// `</script>` sequences escaped, missing hook imports added, and
  /// (when [shouldAutoMount]) the auto-mount snippet appended.
  final String code;

  /// The component the source default-exported, when one was found.
  final String? componentName;

  /// False when the source mounts itself (calls `createRoot` /
  /// `ReactDOM.render`), so the harness must not mount it again.
  final bool shouldAutoMount;

  /// Sibling modules resolved from relative imports, keyed by the
  /// specifier as written (`./Helper`). Empty in single-file mode.
  final Map<String, String> siblingModules;

  /// File names of the resolved siblings, keyed like [siblingModules].
  final Map<String, String> siblingFileNames;

  /// Contents of sibling `.css` files imported by the entry (or by a
  /// sibling), to be inlined as `<style>` by the document builder.
  final List<String> inlinedCss;

  /// Relative imports that could not be resolved to a sibling, and
  /// circular-dependency diagnostics. Non-empty means the bootstrap
  /// surfaces a Preview error instead of running a broken bundle.
  final List<String> siblingErrors;

  const ReactArtifactPreparation({
    required this.code,
    required this.componentName,
    required this.shouldAutoMount,
    this.siblingModules = const {},
    this.siblingFileNames = const {},
    this.inlinedCss = const [],
    this.siblingErrors = const [],
  });
}

/// Resolves a relative specifier (`./Helper`, `./foo.css`) against
/// the sibling file map, trying the bare name plus known module
/// extensions and `index` files. Returns the sibling's file name.
String? resolveSiblingFileName(
  String specifier,
  Map<String, String> siblingFiles,
) {
  final normalized = <String, String>{
    for (final entry in siblingFiles.entries)
      entry.key.replaceFirst(RegExp(r'^\./'), ''): entry.key,
  };
  String lookup(String candidate) =>
      normalized[candidate.replaceFirst(RegExp(r'^\./'), '')] ?? '';
  final base = specifier.replaceFirst(RegExp(r'^\./'), '');
  final candidates = <String>[
    base,
    '$base.tsx',
    '$base.ts',
    '$base.jsx',
    '$base.js',
    '$base.css',
    '$base/index.tsx',
    '$base/index.ts',
    '$base/index.jsx',
    '$base/index.js',
  ];
  for (final candidate in candidates) {
    final found = lookup(candidate);
    if (found.isNotEmpty) return found;
  }
  // Also match by exact key as written.
  if (siblingFiles.containsKey(specifier)) return specifier;
  return null;
}

/// Import statements, capturing the clause (`React, { useState }`,
/// `{ LineChart }`, `* as ns`, or null for a side-effect import) and
/// the module specifier.
final RegExp _importStatementPattern =
    RegExp(r'''import\s+(?:([\s\S]*?)\s+from\s+)?['"]([^'"]+)['"];?''');
final RegExp _defaultDeclPattern =
    RegExp(r'export\s+default\s+(function|class)\s+([A-Za-z_$][\w$]*)');
final RegExp _defaultNamePattern =
    RegExp(r'export\s+default\s+([A-Za-z_$][\w$]*)\s*;?\s*(?=\n|$)');
final RegExp _exportPrefixPattern =
    RegExp(r'export\s+(?=(?:function|const|let|var|class)\s)');
final RegExp _manualHooksPattern =
    RegExp(r'(?:const|let|var)\s*\{([^}]*)\}\s*=\s*React\b');

/// Packages the React document's import map pins to esm.sh builds
/// (see [buildReactArtifactDocument]). Imports of these — and of
/// their subpaths — stay exactly as written; the map resolves them.
const Set<String> _importMappedPackages = {
  'react',
  'react-dom',
  'recharts',
  'lodash',
  'lucide-react',
};

bool _isImportMapped(String specifier) => _importMappedPackages
    .any((pkg) => specifier == pkg || specifier.startsWith('$pkg/'));

/// esm.sh URL for an unmapped bare specifier. `external=react,
/// react-dom` keeps the package on the import map's single React
/// copy — a second React instance would break hooks.
String _esmUrlFor(String specifier) =>
    'https://esm.sh/$specifier?external=react,react-dom';

/// Local names bound by an import clause's `{ … }` section, resolving
/// `name as alias` to the alias (the name the code actually uses).
Set<String> _namedBindings(String? clause) {
  if (clause == null) return const {};
  final braces = RegExp(r'\{([\s\S]*)\}').firstMatch(clause);
  if (braces == null) return const {};
  return braces
      .group(1)!
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .map((part) => part.contains(' as ')
          ? part.split(' as ').last.trim()
          : part.replaceFirst('type ', '').trim())
      .toSet();
}

/// Prepares a React component file to run as an ES module in the
/// harness document, the way modern in-browser runners (import maps +
/// esm.sh) do it:
///
/// - Imports of `react`, `react-dom`, and the curated packages
///   (recharts, lodash, lucide-react) — including subpaths — stay as
///   written; the document's import map resolves them to pinned
///   esm.sh builds that share one React copy.
/// - Any other bare import is rewritten to its esm.sh URL with
///   `external=react,react-dom`, so arbitrary npm packages resolve
///   too. Relative imports and stylesheet imports are dropped — a
///   single-file frame has no sibling files.
/// - `export default function App …` keeps the declaration and records
///   `App`; `export default App;` records `App`; any other default
///   export becomes `const __VeraxiDefaultComponent = …`.
/// - Remaining `export` prefixes on declarations are stripped.
/// - Hooks the code uses but never imports (nor destructures from a
///   React binding) get an `import { … } from 'react'` line — the
///   module-era form of the old global-destructure safety net.
/// - `</script>` inside the source is escaped to `<\/script>` so it
///   cannot terminate the embedding script element early.
/// - Unless the source mounts itself, a snippet is appended that
///   mounts the default export — or a component named App / Component
///   / Demo / Main — into `#root` with React 18's `createRoot`.
ReactArtifactPreparation prepareReactArtifact(
  String source, {
  Map<String, String> siblingFiles = const {},
}) {
  final importedFromReact = <String>{};
  final siblingModules = <String, String>{};
  final siblingFileNames = <String, String>{};
  final inlinedCss = <String>[];
  final siblingErrors = <String>[];

  String? resolveSibling(String specifier) => siblingFiles.isEmpty
      ? null
      : resolveSiblingFileName(specifier, siblingFiles);

  final collectedSiblings = <String>{};

  void collectFromSibling(String fileName) {
    // A sibling's own imports resolve the same way (all siblings
    // live flat in one message): .css imports are inlined, and
    // relative JS imports are registered transitively so the Blob
    // bootstrap can resolve the whole graph — and so circular
    // detection below sees every edge.
    if (!collectedSiblings.add(fileName)) return;
    final siblingSource = siblingFiles[fileName];
    if (siblingSource == null) return;
    for (final m in _importStatementPattern.allMatches(siblingSource)) {
      final spec = m.group(2)!;
      if (spec.endsWith('.css')) {
        final cssFile = resolveSibling(spec);
        if (cssFile != null && !inlinedCss.contains(siblingFiles[cssFile])) {
          inlinedCss.add(siblingFiles[cssFile]!);
        }
        continue;
      }
      if (!spec.startsWith('.')) continue;
      final resolved = resolveSibling(spec);
      if (resolved == null) {
        if (!siblingErrors.any((e) => e.contains(spec))) {
          siblingErrors.add('Missing sibling module: $spec');
        }
        continue;
      }
      siblingModules.putIfAbsent(spec, () => siblingFiles[resolved]!);
      siblingFileNames.putIfAbsent(spec, () => resolved);
      collectFromSibling(resolved);
    }
  }

  var code = source.replaceAllMapped(_importStatementPattern, (match) {
    final clause = match.group(1);
    final specifier = match.group(2)!;
    if (specifier.endsWith('.css')) {
      final cssFile = resolveSibling(specifier);
      if (cssFile != null) {
        final css = siblingFiles[cssFile]!;
        if (!inlinedCss.contains(css)) inlinedCss.add(css);
      }
      return '';
    }
    if (specifier.startsWith('.') || specifier.startsWith('/')) {
      if (siblingFiles.isEmpty) return '';
      final resolved = resolveSibling(specifier);
      if (resolved == null) {
        siblingErrors.add('Missing sibling module: $specifier');
        return match.group(0)!;
      }
      siblingModules[specifier] = siblingFiles[resolved]!;
      siblingFileNames[specifier] = resolved;
      collectFromSibling(resolved);
      return match.group(0)!;
    }
    if (specifier == 'react') {
      importedFromReact.addAll(_namedBindings(clause));
      return match.group(0)!;
    }
    if (_isImportMapped(specifier)) return match.group(0)!;
    final url = _esmUrlFor(specifier);
    return clause == null ? "import '$url';" : "import $clause from '$url';";
  });

  // Circular-import detection over the resolved sibling graph.
  if (siblingModules.isNotEmpty) {
    final graph = <String, List<String>>{};
    siblingModules.forEach((spec, src) {
      graph[spec] = [
        for (final m in _importStatementPattern.allMatches(src))
          if ((m.group(2) ?? '').startsWith('.') &&
              !(m.group(2) ?? '').endsWith('.css'))
            m.group(2)!,
      ];
    });
    final visiting = <String>{};
    final visited = <String>{};
    void dfs(String node) {
      if (visited.contains(node)) return;
      if (visiting.contains(node)) {
        siblingErrors.add('Circular sibling import involving $node');
        return;
      }
      visiting.add(node);
      for (final dep in graph[node] ?? const <String>[]) {
        if (graph.containsKey(dep)) dfs(dep);
      }
      visiting.remove(node);
      visited.add(node);
    }

    for (final node in graph.keys) {
      dfs(node);
    }
  }

  String? componentName;

  final decl = _defaultDeclPattern.firstMatch(code);
  if (decl != null) {
    // `export default function App …` — keep the declaration, drop the
    // export prefix, remember the name.
    componentName = decl.group(2);
    code = code.replaceAllMapped(
      _defaultDeclPattern,
      (m) => '${m.group(1)} ${m.group(2)}',
    );
  } else if (_defaultNamePattern.hasMatch(code)) {
    // `export default App;` as a standalone statement — remember the
    // name and drop the statement.
    componentName = _defaultNamePattern.firstMatch(code)!.group(1);
    code = code.replaceAll(_defaultNamePattern, '');
  } else if (code.contains('export default')) {
    // Any other default export is an expression (anonymous component,
    // arrow function, …): bind it to a constant we can mount.
    componentName = '__VeraxiDefaultComponent';
    code = code.replaceFirst(
      RegExp(r'export\s+default\s+'),
      'const __VeraxiDefaultComponent = ',
    );
  }

  code = code.replaceAll(_exportPrefixPattern, '');

  const hookNames = [
    'useState',
    'useEffect',
    'useRef',
    'useMemo',
    'useCallback',
    'useContext',
    'useReducer',
  ];
  final manuallyBound = <String>{
    for (final match in _manualHooksPattern.allMatches(code))
      ..._namedBindings('{${match.group(1)}}'),
  };
  final missingHooks = hookNames
      .where((h) => code.contains(h))
      .where((h) => !importedFromReact.contains(h))
      .where((h) => !manuallyBound.contains(h))
      .toList();
  if (missingHooks.isNotEmpty) {
    code = "import { ${missingHooks.join(', ')} } from 'react';\n$code";
  }

  final shouldAutoMount =
      !code.contains('createRoot') && !code.contains('ReactDOM.render');

  if (shouldAutoMount) {
    final candidates = <String>[
      if (componentName != null) componentName,
      'App',
      'Component',
      'Demo',
      'Main',
    ];
    final checks =
        candidates.map((n) => "(typeof $n !== 'undefined' && $n)").join(' || ');
    code = '''
import __VeraxiReact from 'react';
import { createRoot as __VeraxiCreateRoot } from 'react-dom/client';
$code
;(function () {
  var __VeraxiComponent = $checks || null;
  var __VeraxiRootEl = document.getElementById('root');
  if (__VeraxiComponent) {
    __VeraxiCreateRoot(__VeraxiRootEl).render(
      __VeraxiReact.createElement(__VeraxiComponent)
    );
  } else {
    __VeraxiRootEl.innerHTML =
      '<pre style="color:#FCA5A5;white-space:pre-wrap">No component found. ' +
      'Export a component by default, or name it App.</pre>';
  }
})();
''';
  }

  // Escape after all transforms: a literal closing script tag anywhere
  // in the source (string, JSX text, comment) would otherwise end the
  // embedding <script type="text/plain"> element early and break out.
  code = code.replaceAll('</script', r'<\/script');

  return ReactArtifactPreparation(
    code: code,
    componentName: componentName,
    shouldAutoMount: shouldAutoMount,
    siblingModules: siblingModules,
    siblingFileNames: siblingFileNames,
    inlinedCss: inlinedCss,
    siblingErrors: siblingErrors,
  );
}

/// The import map for the React harness document: React 18 and the
/// curated library set pinned to free esm.sh builds. The `?external`
/// pins keep every package on this one React copy (a second copy
/// breaks hooks); the trailing-slash entries cover subpath imports
/// (`react/jsx-runtime`, `lodash/debounce`, …).
const String _reactImportMap = '''
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
''';

/// The React harness document: Babel standalone from CDN, the
/// Tailwind Play CDN, and an import map (above); the prepared source
/// sits in an inert text block, and a bootstrap transpiles it
/// (JSX + TypeScript) and injects the result as an ES module.
/// Transform and module-load errors are shown in place of the
/// preview.
String buildReactArtifactDocument(
  String source, {
  Map<String, String> siblingFiles = const {},
}) {
  final prepared = prepareReactArtifact(source, siblingFiles: siblingFiles);
  final cssBlocks = prepared.inlinedCss
      .map((css) =>
          '  <style data-veraxi-sibling-css>\n${css.replaceAll('</style', r'<\/style')}\n  </style>')
      .join('\n');
  final siblingBlocks = prepared.siblingModules.entries
      .map((entry) =>
          '  <script type="text/plain" class="veraxi-sibling-source" '
          'data-spec="${entry.key}" '
          'data-name="${prepared.siblingFileNames[entry.key] ?? entry.key}">\n'
          '${entry.value.replaceAll(RegExp(r"""import\s+(?:[\s\S]*?\s+from\s+)?['"][^'"]*\.css['"];?"""), '').replaceAll('</script', r'<\/script')}\n  </script>')
      .join('\n');
  final siblingErrorsJson = jsonEncode(prepared.siblingErrors);
  final bootstrap =
      prepared.siblingModules.isEmpty && prepared.siblingErrors.isEmpty
          ? _reactBootstrapScript
          : _siblingBootstrapScript(siblingErrorsJson);
  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script src="https://cdn.tailwindcss.com"></script>
  <script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
$veraxiStorageShimScript$veraxiAiShimScript  <script type="importmap">
$_reactImportMap  </script>
  <style>
    body {
      margin: 0;
      padding: 16px;
      background: #141416;
      color: #E2E8F0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
  </style>
$cssBlocks
</head>
<body>
  <div id="root"></div>
  <script type="text/plain" id="veraxi-react-source">
${prepared.code}
  </script>
$siblingBlocks
$bootstrap
</body>
</html>
''';
}

/// The single-file React bootstrap: transpile the entry source with
/// Babel and inject it as an ES module.
const String _reactBootstrapScript = '''
  <script>
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
''';

/// The multi-file React bootstrap: transpile each sibling source,
/// publish it as a Blob module URL (`URL.createObjectURL`), rewrite
/// relative specifiers in transpiled code to those Blob URLs, then
/// inject the entry the same way. Sibling sources whose relative
/// dependencies are not ready yet are deferred until they are; a
/// set that never resolves (missing/circular, also pre-reported in
/// [errorsJson]) surfaces a clear Preview error. Blob module loads
/// require `blob:` in script-src — see PUBLIC_PAGE_CSP on the
/// backend for published pages.
String _siblingBootstrapScript(String errorsJson) {
  return '''
  <script>
    (function () {
      var siblingErrors = $errorsJson;
      function showError(err) {
        document.getElementById('root').innerHTML =
          '<pre style="color:#FCA5A5;white-space:pre-wrap"></pre>';
        document.querySelector('#root pre').textContent =
          'Preview error: ' + (err && err.message ? err.message : err);
      }
      function transpile(src) {
        return Babel.transform(src, {
          sourceType: 'module',
          presets: [
            'react',
            ['typescript', { isTSX: true, allExtensions: true }]
          ]
        }).code;
      }
      function rewriteSpecs(code, blobUrls) {
        Object.keys(blobUrls).forEach(function (spec) {
          code = code.split("'" + spec + "'").join("'" + blobUrls[spec] + "'");
          code = code.split('"' + spec + '"').join('"' + blobUrls[spec] + '"');
        });
        return code;
      }
      function specsIn(code) {
        var specs = [];
        var re = /(?:from\\s+|import\\s+)['"](\\.[^'"]+)['"]/g;
        var m;
        while ((m = re.exec(code)) !== null) specs.push(m[1]);
        return specs;
      }
      try {
        if (siblingErrors.length) {
          showError(siblingErrors.join('; '));
          return;
        }
        var blocks = document.querySelectorAll('.veraxi-sibling-source');
        var pending = {};
        blocks.forEach(function (b) {
          pending[b.getAttribute('data-spec')] = b.textContent;
        });
        var blobUrls = {};
        var progress = true;
        while (progress && Object.keys(pending).length) {
          progress = false;
          Object.keys(pending).forEach(function (spec) {
            var deps = specsIn(pending[spec]).filter(function (d) {
              return d.indexOf('.css') !== d.length - 4;
            });
            var ready = deps.every(function (d) {
              return blobUrls[d] || !pending[d];
            });
            if (!ready) return;
            var out = rewriteSpecs(transpile(pending[spec]), blobUrls);
            var blob = new Blob([out], { type: 'text/javascript' });
            blobUrls[spec] = URL.createObjectURL(blob);
            delete pending[spec];
            progress = true;
          });
        }
        if (Object.keys(pending).length) {
          showError('Circular or missing sibling imports: ' +
            Object.keys(pending).join(', '));
          return;
        }
        var src = document.getElementById('veraxi-react-source').textContent;
        var out = rewriteSpecs(transpile(src), blobUrls);
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
''';
}

/// The two statements a runner document uses to hand its result back to
/// the host. Web iframes post to their parent window; the native WebView
/// posts to its JavaScript channel. Only these two literals are ever
/// passed — [postResultBody] is host code, never user input.
const String postResultToParentWindow =
    'window.parent.postMessage(JSON.stringify(payload), "*");';
const String postResultToWebViewChannel =
    'VeraxiRunner.postMessage(JSON.stringify(payload));';

/// Builds the document that runs [code] as JavaScript entirely on the
/// user's device (browser-only Run): the code executes inside the
/// sandboxed frame, `console.*` output is captured, and the completion
/// value (when not `undefined`) is appended to stdout the way a REPL
/// would print it. The result is posted to the host as JSON:
/// `{runId, stdout, stderr, exitCode}`.
///
/// The code travels base64-encoded so a literal `</script>` inside it
/// cannot break out of the document.
String buildJavaScriptRunnerDocument(
  String code, {
  required String runId,
  required String postResultBody,
}) {
  final encodedCode = base64Encode(utf8.encode(code));
  return '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body>
<script>
(function() {
  var stdoutLines = [];
  var stderrLines = [];
  function format(value) {
    if (typeof value === 'string') return value;
    try {
      var json = JSON.stringify(value);
      return json === undefined ? String(value) : json;
    } catch (e) {
      return String(value);
    }
  }
  function formatArgs(args) {
    return Array.prototype.map.call(args, format).join(' ');
  }
  console.log = function() { stdoutLines.push(formatArgs(arguments)); };
  console.info = console.log;
  console.debug = console.log;
  console.warn = function() { stderrLines.push(formatArgs(arguments)); };
  console.error = function() { stderrLines.push(formatArgs(arguments)); };
  function post(payload) {
    $postResultBody
  }
  try {
    var src = decodeURIComponent(escape(atob("$encodedCode")));
    var result = (0, eval)(src);
    if (result !== undefined) stdoutLines.push(format(result));
    post({
      runId: "$runId",
      stdout: stdoutLines.join("\\n"),
      stderr: stderrLines.join("\\n"),
      exitCode: 0
    });
  } catch (err) {
    if (stderrLines.length) stderrLines.push("");
    stderrLines.push(err && err.stack ? String(err.stack) : String(err));
    post({
      runId: "$runId",
      stdout: stdoutLines.join("\\n"),
      stderr: stderrLines.join("\\n"),
      exitCode: 1
    });
  }
})();
</script>
</body>
</html>
''';
}

/// Builds the document that runs [code] as Python entirely on the
/// user's device via Pyodide (WebAssembly CPython loaded from CDN):
/// stdout/stderr are captured inside the Python session, exceptions
/// print their traceback to stderr, and the result is posted to the
/// host as JSON: `{runId, stdout, stderr, exitCode}`.
///
/// The first run downloads Pyodide (~10 MB) into the frame's cache;
/// later runs reuse it. Packages the code imports (numpy, pandas,
/// matplotlib, …) are auto-loaded from Pyodide's distribution the
/// same way — downloaded on first use, cached afterwards, so plain
/// stdlib code pays nothing for them. The code travels
/// base64-encoded so a literal `</script>` inside it cannot break
/// out of the document.
String buildPythonRunnerDocument(
  String code, {
  required String runId,
  required String postResultBody,
}) {
  final encodedCode = base64Encode(utf8.encode(code));
  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <script>
  (function() {
    // Pyodide reads window.sessionStorage during top-level init, which
    // throws SecurityError in an opaque-origin sandbox="allow-scripts"
    // srcdoc iframe. Provide an ephemeral in-memory Storage shim so
    // Pyodide loads without weakening the sandbox with allow-same-origin.
    function makeMemoryStorage() {
      var store = Object.create(null);
      return {
        get length() { return Object.keys(store).length; },
        key: function(i) { return Object.keys(store)[i] || null; },
        getItem: function(k) {
          return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null;
        },
        setItem: function(k, v) { store[String(k)] = String(v); },
        removeItem: function(k) { delete store[String(k)]; },
        clear: function() { store = Object.create(null); }
      };
    }
    ["sessionStorage", "localStorage"].forEach(function(name) {
      try {
        var _ = window[name];
      } catch (e) {
        try {
          Object.defineProperty(window, name, {
            value: makeMemoryStorage(),
            configurable: true
          });
        } catch (_) {}
      }
    });
  })();
  </script>
  <script src="https://cdn.jsdelivr.net/pyodide/v0.26.2/full/pyodide.js"></script>
</head>
<body>
<script>
(async function() {
  function post(payload) {
    $postResultBody
  }
  try {
    var pyodide = await loadPyodide();
    var rawCode = decodeURIComponent(escape(atob("$encodedCode")));
    // Auto-load the packages the code imports (numpy, pandas, ...)
    // from Pyodide's distribution. A package Pyodide does not ship
    // is not fatal here: execution proceeds and Python's own
    // ModuleNotFoundError names the missing module in the traceback.
    try {
      await pyodide.loadPackagesFromImports(rawCode);
    } catch (pkgErr) {
      console.warn("Package auto-load failed:", pkgErr);
    }
    pyodide.globals.set("__veraxi_user_code", rawCode);
    var result = await pyodide.runPythonAsync(`
import sys
import io
import traceback

sys.stdout = io.StringIO()
sys.stderr = io.StringIO()
__veraxi_exit = 0
try:
    exec(compile(__veraxi_user_code, "<sandbox>", "exec"),
         {"__name__": "__main__"})
except SystemExit as __veraxi_e:
    if isinstance(__veraxi_e.code, int):
        __veraxi_exit = __veraxi_e.code
    elif __veraxi_e.code is not None:
        print(__veraxi_e.code, file=sys.stderr)
        __veraxi_exit = 1
except BaseException:
    traceback.print_exc()
    __veraxi_exit = 1
(sys.stdout.getvalue(), sys.stderr.getvalue(), __veraxi_exit)
`);
    var parts = result.toJs();
    post({
      runId: "$runId",
      stdout: parts[0],
      stderr: parts[1],
      exitCode: parts[2]
    });
  } catch (setupErr) {
    post({
      runId: "$runId",
      stdout: "",
      stderr: "Python runtime failed to load: " + setupErr,
      exitCode: 1
    });
  }
})();
</script>
</body>
</html>
''';
}
