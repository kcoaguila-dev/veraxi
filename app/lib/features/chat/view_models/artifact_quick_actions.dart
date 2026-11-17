import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';

/// One-click code actions for the artifact panel, Canvas-style. Each
/// action is just a prompt template (the Open Canvas model: buttons
/// set a flag that routes to a rewrite with a canned instruction) —
/// the panel sends the built prompt to the chat and the model's reply
/// arrives as a new message artifact, the way Claude iterates.
///
/// Rewrite actions (all but [ArtifactQuickAction.review]) demand the
/// complete updated file back in a single fenced block, so the reply
/// becomes a clean new artifact instead of a fragment.
enum ArtifactQuickAction {
  fixBugs('Fix Bugs'),
  addLogs('Add Logs'),
  review('Review'),
  addComments('Comments');

  const ArtifactQuickAction(this.label);

  /// Chip label in the panel toolbar.
  final String label;

  /// Whether the action's reply is a rewritten file (the panel then
  /// watches for the reply and offers it as an incoming version).
  /// Review answers in prose, so there is nothing to accept.
  bool get producesRewrite => this != ArtifactQuickAction.review;

  String get _instruction => switch (this) {
        ArtifactQuickAction.fixBugs =>
          'Fix the bugs in this code. Reply with the complete updated '
              'file in a single fenced code block, followed by a '
              'one-line summary of each fix.',
        ArtifactQuickAction.addLogs =>
          'Add helpful logging statements to this code (key steps, '
              'inputs, and errors) without changing its behavior. '
              'Reply with the complete updated file in a single '
              'fenced code block.',
        ArtifactQuickAction.review =>
          'Review this code for bugs, security issues, and style '
              'problems. Reply with a structured review grouped by '
              'severity; do not rewrite the whole file.',
        ArtifactQuickAction.addComments =>
          'Add clear explanatory comments and docstrings to this '
              'code without changing its behavior. Reply with the '
              'complete updated file in a single fenced code block.',
      };

  /// Patch-mode instruction used instead of [_instruction] for
  /// rewrite actions on larger files: targeted SEARCH/REPLACE
  /// blocks are cheaper and cannot drift unrelated lines the way a
  /// full-file regeneration can.
  String get _patchInstruction => switch (this) {
        ArtifactQuickAction.fixBugs =>
          'Fix the bugs in this code.',
        ArtifactQuickAction.addLogs =>
          'Add helpful logging statements to this code (key steps, '
              'inputs, and errors) without changing its behavior.',
        ArtifactQuickAction.review => _instruction,
        ArtifactQuickAction.addComments =>
          'Add clear explanatory comments and docstrings to this '
              'code without changing its behavior.',
      };

  String _patchSuffix() {
    return '$_patchInstruction '
        'Return ONLY SEARCH/REPLACE blocks for the changed sections, '
        'in this exact format:\n'
        '<<<<<<< SEARCH\n'
        '<exact existing text>\n'
        '=======\n'
        '<replacement text>\n'
        '>>>>>>> REPLACE\n'
        'Each SEARCH text must match the file exactly once. '
        'If more than 60% of the file changes, return the complete '
        'updated file in a single fenced block instead.';
  }

  /// Builds the chat prompt for this action on [artifact], whose
  /// current code is [currentCode] (the panel's current version,
  /// which may include the user's edits).
  ///
  /// When [selectedText] is non-empty, the action scopes to those
  /// lines ([selectionStartLine]–[selectionEndLine], 1-based) and the
  /// full file rides along as context.
  String buildPrompt({
    required CodeArtifact artifact,
    required String currentCode,
    String? selectedText,
    int? selectionStartLine,
    int? selectionEndLine,
    bool? preferPatch,
  }) {
    // Patch mode defaults on for larger files (~80+ lines), where a
    // full rewrite is slow, token-heavy, and risks unrelated drift.
    // Review never patches: it produces prose, not a rewrite.
    final usePatch = producesRewrite &&
        (preferPatch ?? currentCode.split('\n').length > 80);
    final instruction = usePatch ? _patchSuffix() : _instruction;
    final name = artifact.fileName ?? artifact.title;
    final fence = '```${artifact.language}';
    final buffer = StringBuffer();
    if (selectedText != null && selectedText.trim().isNotEmpty) {
      buffer
        ..writeln(
          'In `$name`, focus on lines $selectionStartLine–'
          '$selectionEndLine:',
        )
        ..writeln()
        ..writeln(fence)
        ..writeln(selectedText.trimRight())
        ..writeln('```')
        ..writeln()
        ..writeln('Full file for context:')
        ..writeln()
        ..writeln(fence)
        ..writeln(currentCode)
        ..writeln('```')
        ..writeln()
        ..write(instruction);
    } else {
      buffer
        ..writeln('`$name`:')
        ..writeln()
        ..writeln(fence)
        ..writeln(currentCode)
        ..writeln('```')
        ..writeln()
        ..write(instruction);
    }
    return buffer.toString();
  }
}
