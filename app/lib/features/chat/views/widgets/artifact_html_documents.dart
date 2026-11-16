/// Builds the standalone HTML documents that artifact previews run in.
///
/// This is the same recipe Claude's artifact pane uses: the content is
/// placed in a self-contained document which the caller runs inside a
/// sandboxed frame (an `<iframe sandbox="allow-scripts" srcdoc>` on web,
/// a WebView on native), so its scripts execute in an opaque origin with
/// no access to the host app, its cookies, or its storage.
///
/// - HTML runs as authored (fragments are wrapped in a base document;
///   full documents pass through untouched).
/// - SVG markup is centered on the artifact background.
/// - Mermaid source is rendered by the Mermaid CDN script.
/// - React/JSX is transpiled in the frame by Babel standalone with
///   React 18 from CDN, and the top-level component is auto-mounted to
///   `#root` — no build step, exactly like Claude's React artifacts.
///
/// Pure Dart on purpose: both platform sandbox implementations share
/// these builders so the documents cannot drift apart, and the React
/// source preparation is unit-testable without a browser.
library;

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
  /// Source with imports/exports rewritten for a script-global React,
  /// `</script>` sequences escaped, hooks destructured, and (when
  /// [shouldAutoMount]) the auto-mount snippet appended.
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

final RegExp _importPattern =
    RegExp(r'''import\s+(?:[\s\S]*?\s+from\s+)?['"][^'"]*['"];?''');
final RegExp _defaultDeclPattern =
    RegExp(r'export\s+default\s+(function|class)\s+([A-Za-z_$][\w$]*)');
final RegExp _defaultNamePattern =
    RegExp(r'export\s+default\s+([A-Za-z_$][\w$]*)\s*;?\s*(?=\n|$)');
final RegExp _exportPrefixPattern =
    RegExp(r'export\s+(?=(?:function|const|let|var|class)\s)');
final RegExp _manualHooksPattern =
    RegExp(r'(?:const|let|var)\s*\{[^}]*\}\s*=\s*React\b');

/// Rewrites a React component file so it can run as a classic script
/// with `React` / `ReactDOM` as globals, the way Claude's harness and
/// other in-browser JSX runners do it:
///
/// - `import` statements are dropped (React is already a global; other
///   packages cannot be resolved in a single-file frame).
/// - `export default function App …` keeps the declaration and records
///   `App`; `export default App;` records `App`; any other default
///   export becomes `const __VeraxiDefaultComponent = …`.
/// - Remaining `export` prefixes on declarations are stripped.
/// - Hooks are destructured from the React global unless the source
///   already does it itself.
/// - `</script>` inside the source is escaped to `<\/script>` so it
///   cannot terminate the embedding script element early.
/// - Unless the source mounts itself, a snippet is appended that mounts
///   the default export — or a component named App / Component / Demo /
///   Main — into `#root` with React 18's `createRoot`.
ReactArtifactPreparation prepareReactArtifact(String source) {
  var code = source.replaceAll(_importPattern, '');

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
  final usesHooks = hookNames.any((h) => code.contains(h));
  if (usesHooks && !_manualHooksPattern.hasMatch(code)) {
    code = 'const { ${hookNames.join(', ')} } = React;\n$code';
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
$code
;(function () {
  var __VeraxiComponent = $checks || null;
  var __VeraxiRootEl = document.getElementById('root');
  if (__VeraxiComponent) {
    ReactDOM.createRoot(__VeraxiRootEl).render(
      React.createElement(__VeraxiComponent)
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

/// The React harness document: React 18 + ReactDOM + Babel standalone
/// from CDN, the prepared source in an inert text block, and a bootstrap
/// that transpiles it (JSX + TypeScript) and injects the result as a
/// classic script. Transform errors are shown in place of the preview.
String buildReactArtifactDocument(String source) {
  final prepared = prepareReactArtifact(source);
  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
  <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
  <script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
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
          presets: [
            'react',
            ['typescript', { isTSX: true, allExtensions: true }]
          ]
        }).code;
        var script = document.createElement('script');
        script.textContent = out;
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
