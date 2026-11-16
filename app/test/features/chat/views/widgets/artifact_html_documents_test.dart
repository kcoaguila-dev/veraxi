import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_html_documents.dart';

void main() {
  group('buildHtmlArtifactDocument', () {
    test('wraps a fragment in the base document', () {
      final doc = buildHtmlArtifactDocument('<button>Hi</button>');
      expect(doc, contains('<button>Hi</button>'));
      expect(doc, contains('<body>'));
      expect(doc, contains('background: #141416'));
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
    test('strips imports and records a default-exported function', () {
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
      expect(prepared.code, isNot(contains('import')));
      expect(prepared.code, contains('function Counter()'));
      expect(prepared.code, isNot(contains('export default')));
      // Hooks are destructured from the React global after import removal.
      expect(prepared.code, contains('const { useState, useEffect'));
      // Auto-mount targets the recorded component first.
      expect(prepared.shouldAutoMount, isTrue);
      expect(prepared.code, contains("typeof Counter !== 'undefined'"));
      expect(prepared.code, contains('ReactDOM.createRoot'));
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
      expect(prepared.code, isNot(contains('useReducer')));
    });
  });

  group('buildReactArtifactDocument', () {
    test('loads React 18, ReactDOM and Babel from CDN with a root node', () {
      final doc = buildReactArtifactDocument(
          'export default function App() { return <div/>; }');
      expect(doc, contains('react@18/umd/react.production.min.js'));
      expect(doc, contains('react-dom@18/umd/react-dom.production.min.js'));
      expect(doc, contains('@babel/standalone/babel.min.js'));
      expect(doc, contains('<div id="root"></div>'));
      expect(doc, contains('Babel.transform'));
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
}
