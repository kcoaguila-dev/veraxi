import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_line_diff.dart';

void main() {
  group('computeLineDiff', () {
    test('identical texts are all unchanged', () {
      final diff = computeLineDiff('a\nb\nc', 'a\nb\nc');
      expect(diff, hasLength(3));
      expect(diff.every((e) => e.kind == LineDiffKind.unchanged), isTrue);
      expect(diff[1].oldLineNumber, 2);
      expect(diff[1].newLineNumber, 2);
    });

    test('empty to non-empty is all additions', () {
      final diff = computeLineDiff('', 'x\ny');
      expect(diff.map((e) => e.kind), [LineDiffKind.added, LineDiffKind.added]);
      expect(diff.first.newLineNumber, 1);
      expect(diff.first.oldLineNumber, isNull);
    });

    test('non-empty to empty is all removals', () {
      final diff = computeLineDiff('x\ny', '');
      expect(diff.map((e) => e.kind),
          [LineDiffKind.removed, LineDiffKind.removed]);
      expect(diff.last.oldLineNumber, 2);
      expect(diff.last.newLineNumber, isNull);
    });

    test('a changed line is a removal followed by an addition', () {
      final diff = computeLineDiff('a\nb\nc', 'a\nB\nc');
      expect(
        diff.map((e) => (e.kind, e.text)),
        [
          (LineDiffKind.unchanged, 'a'),
          (LineDiffKind.removed, 'b'),
          (LineDiffKind.added, 'B'),
          (LineDiffKind.unchanged, 'c'),
        ],
      );
    });

    test('insertion in the middle keeps surrounding lines unchanged', () {
      final diff = computeLineDiff('a\nc', 'a\nb\nc');
      expect(
        diff.map((e) => e.kind),
        [LineDiffKind.unchanged, LineDiffKind.added, LineDiffKind.unchanged],
      );
      expect(diff[1].text, 'b');
      expect(diff[2].oldLineNumber, 2);
      expect(diff[2].newLineNumber, 3);
    });

    test('trailing newline does not create a phantom line', () {
      final diff = computeLineDiff('a\n', 'a\nb\n');
      expect(
        diff.map((e) => (e.kind, e.text)),
        [(LineDiffKind.unchanged, 'a'), (LineDiffKind.added, 'b')],
      );
    });

    test('moved lines diff as remove + add, order preserved', () {
      final diff = computeLineDiff('one\ntwo\nthree', 'three\none\ntwo');
      // Reconstructing the new text from unchanged+added lines, in
      // order, must reproduce it exactly.
      final rebuilt = diff
          .where((e) => e.kind != LineDiffKind.removed)
          .map((e) => e.text)
          .join('\n');
      expect(rebuilt, 'three\none\ntwo');
      final removed = diff
          .where((e) => e.kind != LineDiffKind.added)
          .map((e) => e.text)
          .join('\n');
      expect(removed, 'one\ntwo\nthree');
    });
  });
}
