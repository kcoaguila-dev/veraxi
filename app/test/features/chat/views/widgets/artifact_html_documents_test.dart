import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_html_documents.dart';

void main() {
  group('buildHtmlArtifactDocument', () {
    test('wraps a fragment in the base document', () {
      final doc = buildHtmlArtifactDocument('<button>Hi</button>');
      expect(doc, contains('<button>Hi</button>'));
      expect(doc, contains('<body>'));
      expect(doc, contains('background: #141416'));
      // Fragments get the Tailwind Play CDN, like Claude's harness.
      expect(doc, contains('cdn.tailwindcss.com'));
    });

    test('passes a full document through untouched', () {
      const full = '<!DOCTYPE html>\n<html><head><title>T</title></head>'
          '<body>Full</body></html>';
      expect(buildHtmlArtifactDocument(full), full);
    });
  });

  group('buildSvgArtifactDocument', () {
    test('embeds the raw svg markup', () {
      final doc = buildSvgArtifactDocument('<svg><circle r="4"/></svg>');
      expect(doc, contains('<svg><circle r="4"/></svg>'));
      expect(doc, contains('justify-content: center'));
    });
  });

  group('buildMermaidArtifactDocument', () {
    test('escapes the diagram source and loads mermaid', () {
      final doc = buildMermaidArtifactDocument('graph TD; A-->B');
      expect(doc, contains('mermaid.min.js'));
      expect(doc, contains('graph TD; A--&gt;B'));
      expect(doc, contains('startOnLoad: true'));
    });
  });

  group('prepareReactArtifact', () {
    test('resolves imports and records a default-exported function', () {
      const source = '''
import React, { useState } from 'react';
import './styles.css';

export default function Counter() {
  const [n, setN] = useState(0);
  return <button onClick={() => setN(n + 1)}>{n}</button>;
}
''';
      final prepared = prepareReactArtifact(source);

      expect(prepared.componentName, 'Counter');
      // The react import stays for the import map; the relative
      // stylesheet import is dropped (no sibling files in a frame).
      expect(prepared.code, contains("from 'react'"));
      expect(prepared.code, isNot(contains('styles.css')));
      expect(prepared.code, contains('function Counter()'));
      expect(prepared.code, isNot(contains('export default')));
      // useState is already imported, so no safety-net import is
      // added for it.
      expect('useState'.allMatches(prepared.code).length, 2);
      // Auto-mount targets the recorded component first, via the
      // module imports of React and createRoot.
      expect(prepared.shouldAutoMount, isTrue);
      expect(prepared.code, contains("typeof Counter !== 'undefined'"));
      expect(prepared.code, contains("from 'react-dom/client'"));
      expect(prepared.code, contains('__VeraxiCreateRoot'));
    });

    test('curated packages and subpaths stay for the import map', () {
      const source = '''
import { LineChart } from 'recharts';
import debounce from 'lodash/debounce';
import { Camera } from 'lucide-react';
export default function App() { return <div/>; }
''';
      final prepared = prepareReactArtifact(source);
      expect(prepared.code, contains("from 'recharts'"));
      expect(prepared.code, contains("from 'lodash/debounce'"));
      expect(prepared.code, contains("from 'lucide-react'"));
      expect(prepared.code, isNot(contains('esm.sh')));
    });

    test('unknown bare imports are rewritten to esm.sh URLs', () {
      const source = '''
import { format } from 'date-fns';
import confetti from 'canvas-confetti';
export default function App() { return <div/>; }
''';
      final prepared = prepareReactArtifact(source);
      expect(
        prepared.code,
        contains("from 'https://esm.sh/date-fns?external=react,react-dom'"),
      );
      expect(
        prepared.code,
        contains(
            "from 'https://esm.sh/canvas-confetti?external=react,react-dom'"),
      );
    });

    test('hooks used without an import get one added', () {
      const source = '''
export default function App() {
  const [n] = useState(0);
  useEffect(() => {}, []);
  return <div>{n}</div>;
}
''';
      final prepared = prepareReactArtifact(source);
      expect(
        prepared.code,
        contains("import { useState, useEffect } from 'react';"),
      );
    });

    test('records a bare-name default export and drops the statement', () {
      const source = '''
function App() { return <div>Hello</div>; }
export default App;
''';
      final prepared = prepareReactArtifact(source);

      expect(prepared.componentName, 'App');
      expect(prepared.code, isNot(contains('export default App')));
      expect(prepared.code, contains('function App()'));
    });

    test('binds an anonymous default export to the mount constant', () {
      const source = 'export default () => <div>Hi</div>;';
      final prepared = prepareReactArtifact(source);

      expect(prepared.componentName, '__VeraxiDefaultComponent');
      expect(prepared.code, contains('const __VeraxiDefaultComponent = () =>'));
    });

    test('does not double-mount code that renders itself', () {
      const source = '''
function App() { return <div/>; }
const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(<App />);
''';
      final prepared = prepareReactArtifact(source);

      expect(prepared.shouldAutoMount, isFalse);
      expect(prepared.code, isNot(contains('__VeraxiComponent')));
    });

    test('escapes a closing script tag inside the source', () {
      const source = '''
export default function App() {
  const label = "</script><script>alert(1)</script>";
  return <div>{label}</div>;
}
''';
      final prepared = prepareReactArtifact(source);

      expect(prepared.code, isNot(contains('</script')));
      expect(prepared.code, contains(r'<\/script>'));
    });

    test('keeps a manual hooks destructure instead of adding its own', () {
      const source = '''
const { useState } = React;
export default function App() {
  const [n] = useState(0);
  return <div>{n}</div>;
}
''';
      final prepared = prepareReactArtifact(source);

      expect('const { useState'.allMatches(prepared.code), hasLength(1));
      // No safety-net hook import: useState is already bound by hand.
      expect(prepared.code, isNot(contains('import { useState')));
      expect(prepared.code, isNot(contains('useReducer')));
    });
  });

  group('buildReactArtifactDocument', () {
    test('builds the module harness: import map, Tailwind, Babel', () {
      final doc = buildReactArtifactDocument(
          'export default function App() { return <div/>; }');
      expect(doc, contains('<script type="importmap">'));
      expect(doc, contains('"react": "https://esm.sh/react@18.3.1"'));
      expect(doc, isNot(contains('"react-dom/client"')));
      expect(doc, contains('"react-dom/": "https://esm.sh/react-dom@18.3.1/"'));
      expect(doc, contains('recharts@2.15.0?external=react,react-dom'));
      expect(doc, contains('lucide-react@0.469.0?external=react,react-dom'));
      expect(doc, contains('"lodash": "https://esm.sh/lodash@4.17.21"'));
      expect(doc, contains('cdn.tailwindcss.com'));
      expect(doc, contains('@babel/standalone/babel.min.js'));
      // No UMD globals any more — modules only.
      expect(doc, isNot(contains('umd/react.production.min.js')));
      expect(doc, contains('<div id="root"></div>'));
      expect(doc, contains('Babel.transform'));
      expect(doc, contains("sourceType: 'module'"));
      expect(doc, contains("script.type = 'module'"));
      expect(doc, contains("['typescript', { isTSX: true"));
      expect(doc, contains('id="veraxi-react-source"'));
    });

    test('dispatches by kind', () {
      expect(buildArtifactDocument('react', 'export default () => <div/>'),
          contains('Babel.transform'));
      expect(buildArtifactDocument('svg', '<svg/>'), contains('<svg/>'));
      expect(buildArtifactDocument('html', '<p>x</p>'), contains('<p>x</p>'));
      expect(buildArtifactDocument('mermaid', 'graph TD; A-->B'),
          contains('mermaid.min.js'));
    });
  });

  group('runner documents (browser-only Run)', () {
    test('javascript runner captures console output and posts the result', () {
      final doc = buildJavaScriptRunnerDocument(
        'console.log("hi"); 40 + 2',
        runId: 'run-1',
        postResultBody: postResultToParentWindow,
      );
      expect(doc, contains('console.log = function()'));
      expect(doc, contains('console.error = function()'));
      expect(doc, contains('(0, eval)'));
      expect(doc, contains('runId: "run-1"'));
      expect(
          doc, contains('window.parent.postMessage(JSON.stringify(payload)'));
      // The code itself travels base64-encoded, never inlined raw.
      expect(doc, isNot(contains('console.log("hi"); 40 + 2')));
    });

    test('javascript runner can post over the WebView channel instead', () {
      final doc = buildJavaScriptRunnerDocument(
        '1 + 1',
        runId: 'run-2',
        postResultBody: postResultToWebViewChannel,
      );
      expect(doc, contains('VeraxiRunner.postMessage(JSON.stringify('));
      expect(doc, isNot(contains('window.parent.postMessage')));
    });

    test('python runner loads Pyodide and captures stdout in-session', () {
      final doc = buildPythonRunnerDocument(
        'print("hello")',
        runId: 'run-3',
        postResultBody: postResultToParentWindow,
      );
      expect(doc, contains('cdn.jsdelivr.net/pyodide/v0.26.2'));
      expect(doc, contains('loadPyodide()'));
      expect(doc, contains('sys.stdout = io.StringIO()'));
      expect(doc, contains('traceback.print_exc()'));
      expect(doc, contains('SystemExit'));
      expect(doc, contains('runId: "run-3"'));
      expect(doc, isNot(contains('print("hello")')));
    });

    test('python runner auto-loads imported packages (numpy/pandas)', () {
      final doc = buildPythonRunnerDocument(
        'import pandas',
        runId: 'run-5',
        postResultBody: postResultToParentWindow,
      );
      // Imported packages load from Pyodide's distribution before
      // the user code executes; a load failure is non-fatal so the
      // run still surfaces Python's own ModuleNotFoundError.
      expect(doc, contains('loadPackagesFromImports(rawCode)'));
      expect(
        doc.indexOf('loadPackagesFromImports'),
        lessThan(doc.indexOf('runPythonAsync')),
      );
    });

    test('a literal closing script tag in the code cannot break out', () {
      final doc = buildJavaScriptRunnerDocument(
        'var s = "</script><script>alert(1)</scr" + "ipt>";',
        runId: 'run-4',
        postResultBody: postResultToParentWindow,
      );
      // Only the runner's own two script tags exist in the document.
      expect('</script>'.allMatches(doc), hasLength(1));
      expect(doc, isNot(contains('alert(1)</scr')));
    });
  });
}
