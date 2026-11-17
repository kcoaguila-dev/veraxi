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

    test('passes a full document through with only the shim added', () {
      const full = '<!DOCTYPE html>\n<html><head><title>T</title></head>'
          '<body>Full</body></html>';
      final doc = buildHtmlArtifactDocument(full);
      // No nesting/wrapping: the authored document survives verbatim
      // apart from the injected veraxiStorage shim before </head>.
      expect(doc, contains('<title>T</title>'));
      expect(doc, contains('<body>Full</body>'));
      expect(doc, contains('window.veraxiStorage'));
      expect(doc.indexOf('window.veraxiStorage'),
          lessThan(doc.indexOf('</head>')));
    });

    test('every document kind carries the storage shim', () {
      expect(buildHtmlArtifactDocument('<p>x</p>'),
          contains('window.veraxiStorage'));
      expect(
          buildSvgArtifactDocument('<svg/>'), contains('window.veraxiStorage'));
      expect(buildMermaidArtifactDocument('graph TD; A-->B'),
          contains('window.veraxiStorage'));
      expect(
          buildReactArtifactDocument(
              'export default function App() { return <div/>; }'),
          contains('window.veraxiStorage'));
      // The Claude-compat alias ships too.
      expect(buildHtmlArtifactDocument('<p>x</p>'),
          contains('window.storage = api'));
    });
  });

  group('AI bridge shim (window.veraxi.complete)', () {
    test('html and react documents carry the shim and the claude alias', () {
      final html = buildHtmlArtifactDocument('<p>x</p>');
      expect(html, contains('veraxi_complete'));
      expect(html, contains('window.veraxi'));
      expect(html, contains('veraxi.complete = complete'));
      // Claude-compat alias for artifacts written against
      // window.claude.complete.
      expect(html, contains('window.claude'));
      expect(html, contains('claude.complete = complete'));
      expect(html, contains('__veraxiCompleteReply'));

      final react = buildReactArtifactDocument(
          'export default function App() { return <div/>; }');
      expect(react, contains('veraxi_complete'));
      expect(react, contains('window.claude'));
    });

    test('a full authored document gets the shim before </head>', () {
      const full = '<!DOCTYPE html>\n<html><head><title>T</title></head>'
          '<body>Full</body></html>';
      final doc = buildHtmlArtifactDocument(full);
      expect(doc, contains('veraxi_complete'));
      expect(doc.indexOf('veraxi_complete'), lessThan(doc.indexOf('</head>')));
    });

    test('the shim carries no credential material', () {
      // The frame must never receive a key, token, or auth header:
      // the shim transports only the prompt the artifact wrote.
      final html = buildHtmlArtifactDocument('<p>x</p>');
      expect(html, isNot(contains('Authorization')));
      expect(html, isNot(contains('X-BYOD')));
      expect(html, isNot(contains('api_key')));
      expect(html, isNot(contains('Bearer')));
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

  group('prepareReactArtifact with sibling files', () {
    const entry = '''
import Helper from './Helper';
import './styles.css';
export default function App() { return <Helper/>; }
''';
    const siblings = {
      'Helper.tsx': 'export default function Helper() { return <div/>; }',
      'styles.css': '.x { color: red; }',
    };

    test('inlines an imported sibling stylesheet', () {
      final prepared = prepareReactArtifact(entry, siblingFiles: siblings);
      expect(prepared.inlinedCss, ['.x { color: red; }']);
      final doc = buildReactArtifactDocument(entry, siblingFiles: siblings);
      expect(doc, contains('data-veraxi-sibling-css'));
      expect(doc, contains('.x { color: red; }'));
    });

    test('resolves a relative sibling module for the Blob bootstrap', () {
      final prepared = prepareReactArtifact(entry, siblingFiles: siblings);
      expect(prepared.siblingModules.keys, ['./Helper']);
      expect(prepared.siblingFileNames['./Helper'], 'Helper.tsx');
      expect(prepared.siblingErrors, isEmpty);
      // The entry import stays; the bootstrap rewrites it to a Blob URL.
      expect(prepared.code, contains("from './Helper'"));
      final doc = buildReactArtifactDocument(entry, siblingFiles: siblings);
      expect(doc, contains('class="veraxi-sibling-source"'));
      expect(doc, contains('data-spec="./Helper"'));
      expect(doc, contains('URL.createObjectURL'));
      expect(doc, contains('new Blob'));
    });

    test('single-file mode still drops relative imports', () {
      final prepared = prepareReactArtifact(entry);
      expect(prepared.siblingModules, isEmpty);
      expect(prepared.code, isNot(contains('./Helper')));
      final doc = buildReactArtifactDocument(entry);
      expect(doc, isNot(contains('veraxi-sibling-source')));
    });

    test('missing sibling import is a clear Preview error', () {
      final prepared = prepareReactArtifact(entry, siblingFiles: const {
        'Other.tsx': 'export default function Other() { return <div/>; }',
      });
      expect(
        prepared.siblingErrors.single,
        contains('Missing sibling module: ./Helper'),
      );
      final doc = buildReactArtifactDocument(entry, siblingFiles: const {
        'Other.tsx': 'export default function Other() { return <div/>; }',
      });
      expect(doc, contains('Missing sibling module: ./Helper'));
      expect(doc, contains('Preview error'));
    });

    test('circular sibling imports are reported', () {
      const circularEntry = '''
import A from './A';
export default function App() { return <A/>; }
''';
      final prepared = prepareReactArtifact(circularEntry, siblingFiles: {
        'A.tsx':
            "import B from './B'; export default function A() { return <B/>; }",
        'B.tsx':
            "import A from './A'; export default function B() { return <A/>; }",
      });
      // A imports ./B and B imports ./A: resolution is transitive,
      // so both modules ship and the cycle is reported as an error.
      expect(prepared.siblingModules.keys, containsAll(['./A', './B']));
      expect(
        prepared.siblingErrors.any((e) => e.contains('Circular')),
        isTrue,
      );
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

    test('python runner shims sessionStorage before loading Pyodide', () {
      final doc = buildPythonRunnerDocument(
        'print("hello")',
        runId: 'run-shim',
        postResultBody: postResultToParentWindow,
      );
      expect(doc, contains('sessionStorage'));
      expect(doc, contains('Object.defineProperty(window'));
      expect(
        doc.indexOf('sessionStorage'),
        lessThan(doc.indexOf('pyodide.js')),
      );
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
