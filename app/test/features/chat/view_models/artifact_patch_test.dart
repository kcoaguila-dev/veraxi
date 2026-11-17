import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_patch.dart';

void main() {
  group('applyArtifactPatches', () {
    test('applies a single-hunk patch', () {
      const original = 'line1\nline2\nline3\n';
      const reply = '''
<<<<<<< SEARCH
line2
=======
LINE2
>>>>>>> REPLACE
''';
      final result = applyArtifactPatches(original, reply);
      expect(result.isSuccess, isTrue);
      expect(result.patchedCode, 'line1\nLINE2\nline3\n');
      expect(result.appliedCount, 1);
      expect(result.isFullFileFallback, isFalse);
    });

    test('applies multi-hunk patches inside a diff fence, in order', () {
      const original = 'a\nb\nc\nd\n';
      const reply = '''
```diff
<<<<<<< SEARCH
a
=======
A
>>>>>>> REPLACE
<<<<<<< SEARCH
d
=======
D
>>>>>>> REPLACE
```
''';
      final result = applyArtifactPatches(original, reply);
      expect(result.isSuccess, isTrue);
      expect(result.patchedCode, 'A\nb\nc\nD\n');
      expect(result.appliedCount, 2);
    });

    test('handles CRLF originals and replies', () {
      const original = 'one\r\ntwo\r\nthree\r\n';
      const reply = '<<<<<<< SEARCH\r\ntwo\r\n=======\r\nTWO\r\n'
          '>>>>>>> REPLACE\r\n';
      final result = applyArtifactPatches(original, reply);
      expect(result.isSuccess, isTrue);
      expect(result.patchedCode, 'one\nTWO\nthree\n');
    });

    test('preserves surrounding whitespace exactly', () {
      const original = '  indented\n\ttabbed\n';
      const reply = '''
<<<<<<< SEARCH
\ttabbed
=======
\ttabbed twice
>>>>>>> REPLACE
''';
      final result = applyArtifactPatches(original, reply);
      expect(result.patchedCode, '  indented\n\ttabbed twice\n');
    });

    test('missing SEARCH text fails closed with diagnostics', () {
      final result = applyArtifactPatches(
        'hello\n',
        '<<<<<<< SEARCH\nnot present\n=======\nx\n>>>>>>> REPLACE\n',
      );
      expect(result.isSuccess, isFalse);
      expect(result.patchedCode, isNull);
      expect(result.failedBlocks, hasLength(1));
      expect(result.failedBlocks.single.reason, contains('not found'));
    });

    test('ambiguous SEARCH text fails closed', () {
      final result = applyArtifactPatches(
        'same\nsame\n',
        '<<<<<<< SEARCH\nsame\n=======\nother\n>>>>>>> REPLACE\n',
      );
      expect(result.isSuccess, isFalse);
      expect(result.patchedCode, isNull);
      expect(result.failedBlocks.single.reason, contains('more than once'));
    });

    test('one failing hunk rejects the whole patch (no partial apply)', () {
      const reply = '''
<<<<<<< SEARCH
a
=======
A
>>>>>>> REPLACE
<<<<<<< SEARCH
missing
=======
M
>>>>>>> REPLACE
''';
      final result = applyArtifactPatches('a\nb\n', reply);
      expect(result.isSuccess, isFalse);
      expect(result.patchedCode, isNull);
      expect(result.appliedCount, 1);
      expect(result.failedBlocks, hasLength(1));
    });

    test('unterminated block is a malformed failure, not dropped', () {
      final result = applyArtifactPatches(
        'a\n',
        '<<<<<<< SEARCH\na\n=======\nA\n',
      );
      expect(result.isSuccess, isFalse);
      expect(result.failedBlocks.single.reason, contains('malformed'));
    });

    test('full-file fenced reply is a fallback', () {
      final result = applyArtifactPatches(
        'old\n',
        'Here:\n\n```python\nprint("new")\n```\n',
      );
      expect(result.isSuccess, isTrue);
      expect(result.isFullFileFallback, isTrue);
      expect(result.patchedCode, 'print("new")');
    });

    test('reply with neither patches nor fences fails', () {
      final result = applyArtifactPatches('a\n', 'just prose');
      expect(result.isSuccess, isFalse);
      expect(result.patchedCode, isNull);
    });
  });
}
