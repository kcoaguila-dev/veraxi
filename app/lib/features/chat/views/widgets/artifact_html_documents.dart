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
String buildArtifactDocument(String kind, String code) {
  return switch (kind) {
    'svg' => buildSvgArtifactDocument(code),
    'mermaid' => buildMermaidArtifactDocument(code),
    'react' => buildReactArtifactDocument(code),
    _ => buildHtmlArtifactDocument(code),
  };
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
  // already self-contained; wrapping it would nest documents.
  if (code.toLowerCase().contains('<html')) return code;
  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
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
  <style>
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
  <style>
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

  const ReactArtifactPreparation({
    required this.code,
    required this.componentName,
    required this.shouldAutoMount,
  });
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
ReactArtifactPreparation prepareReactArtifact(String source) {
  final importedFromReact = <String>{};
  var code = source.replaceAllMapped(_importStatementPattern, (match) {
    final clause = match.group(1);
    final specifier = match.group(2)!;
    if (specifier.endsWith('.css')) return '';
    if (specifier.startsWith('.') || specifier.startsWith('/')) return '';
    if (specifier == 'react') {
      importedFromReact.addAll(_namedBindings(clause));
      return match.group(0)!;
    }
    if (_isImportMapped(specifier)) return match.group(0)!;
    final url = _esmUrlFor(specifier);
    return clause == null ? "import '$url';" : "import $clause from '$url';";
  });

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
String buildReactArtifactDocument(String source) {
  final prepared = prepareReactArtifact(source);
  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script src="https://cdn.tailwindcss.com"></script>
  <script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
  <script type="importmap">
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
</head>
<body>
  <div id="root"></div>
  <script type="text/plain" id="veraxi-react-source">
${prepared.code}
  </script>
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
</body>
</html>
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
