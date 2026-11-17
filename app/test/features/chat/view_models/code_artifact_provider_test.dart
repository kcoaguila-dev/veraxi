import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';

void main() {
  group('extractCodeArtifacts', () {
    test('pairs a Claude-style file mention with its code block', () {
      const markdown = '''
Here's `hello_world.py`:

```python
def main():
    print("Hello, World!")


if __name__ == "__main__":
    main()
```

Run it with python hello_world.py and it prints Hello, World!
''';

      final artifacts = extractCodeArtifacts(markdown);

      expect(artifacts, hasLength(1));
      final artifact = artifacts.single;
      expect(artifact.fileName, 'hello_world.py');
      expect(artifact.title, 'Hello world');
      expect(artifact.extensionLabel, 'PY');
      expect(artifact.language, 'python');
      expect(artifact.lineCount, 6);
      expect(artifact.code, contains('print("Hello, World!")'));
    });

    test('falls back to a language title when no file is named', () {
      const markdown = '''
```dart
void main() => print('hi');
```
''';

      final artifacts = extractCodeArtifacts(markdown);

      expect(artifacts, hasLength(1));
      expect(artifacts.single.fileName, isNull);
      expect(artifacts.single.title, 'Dart code');
      expect(artifacts.single.extensionLabel, 'DART');
      expect(artifacts.single.language, 'dart');
    });

    test('keeps multiple blocks in order with their own file names', () {
      const markdown = '''
First, `first_file.py`:

```python
print(1)
```

Then `second-file.ts`:

```ts
export const x = 2;
```
''';

      final artifacts = extractCodeArtifacts(markdown);

      expect(artifacts, hasLength(2));
      expect(artifacts[0].fileName, 'first_file.py');
      expect(artifacts[0].title, 'First file');
      expect(artifacts[1].fileName, 'second-file.ts');
      expect(artifacts[1].title, 'Second file');
      expect(artifacts[1].language, 'typescript');
      expect(artifacts[1].extensionLabel, 'TS');
    });

    test('does not attribute a file named after the block to that block', () {
      const markdown = '''
```python
print(1)
```

Save that as later.py if you like.
''';

      final artifacts = extractCodeArtifacts(markdown);

      expect(artifacts, hasLength(1));
      expect(artifacts.single.fileName, isNull);
    });

    test('does not mistake abbreviations or versions for file names', () {
      const markdown = '''
Use e.g. the snippet below (needs v1.2 or later):

```python
print(1)
```
''';

      final artifacts = extractCodeArtifacts(markdown);

      expect(artifacts.single.fileName, isNull);
      expect(artifacts.single.title, 'Python code');
    });

    test('reads a file name from a first-line comment', () {
      const markdown = '''
```python
# sort_items.py
items = sorted([3, 1, 2])
```
''';

      final artifacts = extractCodeArtifacts(markdown);

      expect(artifacts.single.fileName, 'sort_items.py');
      expect(artifacts.single.title, 'Sort items');
    });

    test('ignores an unclosed fence while the reply is streaming', () {
      const markdown = '''
```python
def main():
    print("still typing
''';

      expect(extractCodeArtifacts(markdown), isEmpty);
    });

    test('returns nothing for prose without code blocks', () {
      expect(extractCodeArtifacts('Just a normal answer.'), isEmpty);
      expect(extractCodeArtifacts(''), isEmpty);
    });

    test('treats a fence without a language as plain text', () {
      const markdown = '''
```
plain output
second line
```
''';

      final artifacts = extractCodeArtifacts(markdown);

      expect(artifacts.single.language, 'plaintext');
      expect(artifacts.single.title, 'Plain text code');
      expect(artifacts.single.extensionLabel, 'TXT');
    });

    test('keeps shell commands and 1-line plain output inline', () {
      const markdown = '''
Here's a simple "Hello World" program in Python:

```python
# hello_world.py
print("Hello World")
```

Save it as `hello_world.py` and run it with:

```bash
python hello_world.py
```

It will output:

```
Hello World
```
''';

      final artifacts = extractCodeArtifacts(markdown);

      expect(artifacts, hasLength(1));
      expect(artifacts.single.fileName, 'hello_world.py');
      expect(artifacts.single.language, 'python');

      final stripped = stripCodeArtifacts(markdown);
      expect(stripped, contains('python hello_world.py'));
      expect(stripped, contains('Hello World'));
      expect(stripped, isNot(contains('print("Hello World")')));
    });

    test('keeps mistagged 1-line python shell invocations inline', () {
      const markdown = '''
```python
# hello_world.py
print("Hello World")
```

Save it as `hello_world.py` and run it with:

```python
python hello_world.py
```
''';

      final artifacts = extractCodeArtifacts(markdown);
      expect(artifacts, hasLength(1));
      expect(artifacts.single.fileName, 'hello_world.py');
    });

    test('promotes bash blocks when paired with a shell script file name', () {
      const markdown = '''
Create `deploy.sh`:

```bash
#!/usr/bin/env bash
echo "deploying"
```
''';

      final artifacts = extractCodeArtifacts(markdown);
      expect(artifacts, hasLength(1));
      expect(artifacts.single.fileName, 'deploy.sh');
      expect(artifacts.single.language, 'bash');
    });
  });

  group('previewKind', () {
    CodeArtifact artifact(String language, String code, {String? fileName}) =>
        CodeArtifact.fromCode(
            language: language, code: code, fileName: fileName);

    test('html, svg, mermaid and markdown blocks are previewable', () {
      expect(artifact('html', '<button>Hi</button>').previewKind,
          CodePreviewKind.html);
      expect(artifact('svg', '<svg></svg>').previewKind, CodePreviewKind.svg);
      expect(artifact('mermaid', 'graph TD; A-->B').previewKind,
          CodePreviewKind.mermaid);
      expect(artifact('md', '# Title').previewKind, CodePreviewKind.markdown);
      expect(artifact('markdown', '# Title').previewKind,
          CodePreviewKind.markdown);
    });

    test('file extensions drive the kind when the fence is generic', () {
      expect(artifact('xml', '<svg></svg>', fileName: 'icon.svg').previewKind,
          CodePreviewKind.svg);
      expect(
          artifact('plaintext', '<p>x</p>', fileName: 'page.html').previewKind,
          CodePreviewKind.html);
      expect(artifact('plaintext', '# Hi', fileName: 'notes.md').previewKind,
          CodePreviewKind.markdown);
    });

    test('an xml block whose content is an svg is an svg preview', () {
      expect(artifact('xml', '  <svg viewBox="0 0 1 1"></svg>').previewKind,
          CodePreviewKind.svg);
      expect(
          artifact('xml', '<div>page</div>').previewKind, CodePreviewKind.html);
    });

    test('jsx and tsx blocks are react previews', () {
      expect(artifact('jsx', 'export default () => <div/>').previewKind,
          CodePreviewKind.react);
      expect(
          artifact('tsx', 'export default function App() { return <div/>; }')
              .previewKind,
          CodePreviewKind.react);
    });

    test('javascript with a default-exported JSX component is react', () {
      const code = '''
import React from 'react';
export default function Counter() {
  const [n, setN] = useState(0);
  return <button>{n}</button>;
}
''';
      expect(artifact('javascript', code).previewKind, CodePreviewKind.react);
    });

    test('plain javascript and python are not previewable', () {
      expect(artifact('javascript', 'const x = 1 < 2 ? "a" : "b";').previewKind,
          CodePreviewKind.none);
      expect(
          artifact('python', 'print("hi")').previewKind, CodePreviewKind.none);
      expect(
          artifact('dart', 'void main() {}').previewKind, CodePreviewKind.none);
      expect(artifact('python', 'print("hi")').isPreviewable, isFalse);
      expect(artifact('html', '<p>x</p>').isPreviewable, isTrue);
    });

    test('highlight language maps html and svg to xml', () {
      expect(artifact('html', '<p>x</p>').highlightLanguage, 'xml');
      expect(artifact('svg', '<svg/>').highlightLanguage, 'xml');
      expect(artifact('python', 'x = 1').highlightLanguage, 'python');
    });
  });

  group('helpers', () {
    test('humanizeFileName matches the Claude card titles', () {
      expect(humanizeFileName('hello_world.py'), 'Hello world');
      expect(humanizeFileName('chat-screen.dart'), 'Chat screen');
      expect(humanizeFileName('main.py'), 'Main');
    });

    test('normalizeCodeLanguage resolves aliases', () {
      expect(normalizeCodeLanguage('py'), 'python');
      expect(normalizeCodeLanguage('python3'), 'python');
      expect(normalizeCodeLanguage('js'), 'javascript');
      expect(normalizeCodeLanguage('ts'), 'typescript');
      expect(normalizeCodeLanguage('c++'), 'cpp');
      expect(normalizeCodeLanguage('html'), 'html');
      expect(normalizeCodeLanguage('md'), 'markdown');
      expect(normalizeCodeLanguage('text'), 'plaintext');
      expect(normalizeCodeLanguage('dart'), 'dart');
    });
  });

  group('stripCodeArtifacts', () {
    test('removes fenced blocks and keeps the surrounding prose', () {
      const md = 'Intro text.\n\n```python\nprint("hi")\n```\n\nAfter.';
      final stripped = stripCodeArtifacts(md);
      expect(stripped, contains('Intro text.'));
      expect(stripped, contains('After.'));
      expect(stripped, isNot(contains('print')));
      expect(stripped, isNot(contains('```')));
    });

    test('a message that is only a block strips to empty', () {
      expect(stripCodeArtifacts('```python\nx = 1\n```'), isEmpty);
    });

    test('leaves an unclosed (streaming) fence in place', () {
      const md = 'Working:\n\n```python\nprint("part';
      expect(stripCodeArtifacts(md), md.trim());
    });

    test('strips exactly the blocks extractCodeArtifacts finds', () {
      const md = 'A\n\n```dart\nvoid main() {}\n```\n\nB\n\n```js\n1\n```';
      expect(extractCodeArtifacts(md), hasLength(2));
      final stripped = stripCodeArtifacts(md);
      expect(stripped, contains('A'));
      expect(stripped, contains('B'));
      expect(stripped, isNot(contains('void main')));
    });
  });

  group('resolveOpenCodeArtifact', () {
    const snapshot = CodeArtifact(
      title: 'Hello world',
      fileName: 'hello_world.py',
      language: 'python',
      code: 'print("v1")',
    );
    const open = OpenCodeArtifact(
      artifact: snapshot,
      threadId: 't1',
      messageIndex: 0,
      artifactIndex: 0,
    );

    ChatState stateWith(String content, {String? threadId = 't1'}) {
      return ChatState(
        threadId: threadId,
        messages: [ChatMessage(role: 'assistant', content: content)],
      );
    }

    test('follows the live content of a streaming message', () {
      final resolved = resolveOpenCodeArtifact(
        open,
        stateWith('```python\nprint("v2")\n```'),
      );
      expect(resolved.code, 'print("v2")');
    });

    test('falls back to the snapshot for another thread', () {
      final resolved = resolveOpenCodeArtifact(
        open,
        stateWith('```python\nprint("v2")\n```', threadId: 'other'),
      );
      expect(resolved, snapshot);
    });

    test('falls back when the message position is gone', () {
      final resolved = resolveOpenCodeArtifact(
        open,
        ChatState(threadId: 't1', messages: const []),
      );
      expect(resolved, snapshot);
    });

    test('falls back while the fence is still unclosed', () {
      final resolved = resolveOpenCodeArtifact(
        open,
        stateWith('```python\nprint("v2")'),
      );
      expect(resolved, snapshot);
    });

    test('no coordinates means the snapshot is all there is', () {
      const bare = OpenCodeArtifact(artifact: snapshot);
      final resolved = resolveOpenCodeArtifact(
        bare,
        stateWith('```python\nprint("v2")\n```'),
      );
      expect(resolved, snapshot);
    });
  });

  group('CodeArtifact.downloadFileName', () {
    test('uses the real file name when there is one', () {
      const artifact = CodeArtifact(
        title: 'Hello world',
        fileName: 'hello_world.py',
        language: 'python',
        code: 'x',
      );
      expect(artifact.downloadFileName, 'hello_world.py');
    });

  group('collectSiblingArtifacts', () {
    const multiFile = '''
Here is `App.tsx`:

```tsx
export default function App() { return <div/>; }
```

And `Helper.tsx`:

```tsx
export default function Helper() { return <div/>; }
```

And `styles.css`:

```css
.x { color: red; }
```

An anonymous snippet:

```python
print("no file name")
```
''';

    ChatState state() => ChatState(
          threadId: 't1',
          messages: [ChatMessage(role: 'assistant', content: multiFile)],
        );

    test('returns every named artifact from the same message', () {
      const open = OpenCodeArtifact(
        artifact: CodeArtifact(
          title: 'App',
          fileName: 'App.tsx',
          language: 'tsx',
          code: '',
        ),
        threadId: 't1',
        messageIndex: 0,
        artifactIndex: 0,
      );
      final siblings = collectSiblingArtifacts(state(), open);
      expect(
        siblings.map((a) => a.fileName),
        ['App.tsx', 'Helper.tsx', 'styles.css'],
      );
    });

    test('empty for other threads, missing index, or out of range', () {
      const open = OpenCodeArtifact(
        artifact: CodeArtifact(
          title: 'App',
          fileName: 'App.tsx',
          language: 'tsx',
          code: '',
        ),
        threadId: 'other',
        messageIndex: 0,
      );
      expect(collectSiblingArtifacts(state(), open), isEmpty);
      const noIndex = OpenCodeArtifact(
        artifact: CodeArtifact(
          title: 'App',
          fileName: 'App.tsx',
          language: 'tsx',
          code: '',
        ),
        threadId: 't1',
      );
      expect(collectSiblingArtifacts(state(), noIndex), isEmpty);
    });
  });

    test('derives artifact.<ext> from the language otherwise', () {
      CodeArtifact anon(String language) => CodeArtifact(
            title: 'code',
            fileName: null,
            language: language,
            code: 'x',
          );
      expect(anon('python').downloadFileName, 'artifact.py');
      expect(anon('javascript').downloadFileName, 'artifact.js');
      expect(anon('markdown').downloadFileName, 'artifact.md');
      expect(anon('dart').downloadFileName, 'artifact.dart');
    });
  });
}
