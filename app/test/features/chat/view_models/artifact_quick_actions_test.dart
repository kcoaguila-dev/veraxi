import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_quick_actions.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';

void main() {
  const artifact = CodeArtifact(
    title: 'Hello world',
    fileName: 'hello_world.py',
    language: 'python',
    code: 'print("hi")',
  );
  const code = 'def main():\n    print("hi")';

  group('ArtifactQuickAction.buildPrompt', () {
    test('whole-file fix demands the complete updated file back', () {
      final prompt = ArtifactQuickAction.fixBugs.buildPrompt(
        artifact: artifact,
        currentCode: code,
      );
      expect(prompt, contains('`hello_world.py`'));
      expect(prompt, contains('```python\n$code\n```'));
      expect(prompt, contains('complete updated file'));
      expect(prompt, contains('Fix the bugs'));
    });

    test('review asks for findings, not a rewrite', () {
      final prompt = ArtifactQuickAction.review.buildPrompt(
        artifact: artifact,
        currentCode: code,
      );
      expect(prompt, contains('structured review'));
      expect(prompt, contains('do not rewrite'));
    });

    test('selection scopes the action and keeps the file as context', () {
      final prompt = ArtifactQuickAction.addLogs.buildPrompt(
        artifact: artifact,
        currentCode: code,
        selectedText: '    print("hi")',
        selectionStartLine: 2,
        selectionEndLine: 2,
      );
      expect(prompt, contains('focus on lines 2–2'));
      expect(prompt, contains('Full file for context:'));
      // Selected text appears twice: once as the focus block, once
      // inside the full file.
      expect('print("hi")'.allMatches(prompt).length, 2);
    });

    test('large files default to patch mode', () {
      final big = List.generate(100, (i) => 'line $i').join('\n');
      final prompt = ArtifactQuickAction.fixBugs.buildPrompt(
        artifact: artifact,
        currentCode: big,
      );
      expect(prompt, contains('SEARCH/REPLACE'));
      expect(prompt, contains('<<<<<<< SEARCH'));
      expect(prompt, contains('more than 60%'));
    });

    test('preferPatch false forces a full rewrite even for large files', () {
      final big = List.generate(100, (i) => 'line $i').join('\n');
      final prompt = ArtifactQuickAction.fixBugs.buildPrompt(
        artifact: artifact,
        currentCode: big,
        preferPatch: false,
      );
      expect(prompt, contains('complete updated file'));
      expect(prompt, isNot(contains('SEARCH/REPLACE')));
    });

    test('review never uses patch mode', () {
      final big = List.generate(100, (i) => 'line $i').join('\n');
      final prompt = ArtifactQuickAction.review.buildPrompt(
        artifact: artifact,
        currentCode: big,
        preferPatch: true,
      );
      expect(prompt, contains('structured review'));
    });

    test('whitespace-only selection falls back to the whole file', () {
      final prompt = ArtifactQuickAction.addComments.buildPrompt(
        artifact: artifact,
        currentCode: code,
        selectedText: '   ',
        selectionStartLine: 1,
        selectionEndLine: 1,
      );
      expect(prompt, isNot(contains('focus on lines')));
      expect(prompt, contains('comments and docstrings'));
    });
  });
}
