import 'package:flutter_test/flutter_test.dart';
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
      expect(normalizeCodeLanguage('html'), 'xml');
      expect(normalizeCodeLanguage('text'), 'plaintext');
      expect(normalizeCodeLanguage('dart'), 'dart');
    });
  });
}
