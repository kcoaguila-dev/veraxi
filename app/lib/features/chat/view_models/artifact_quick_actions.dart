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
  }) {
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
        ..write(_instruction);
    } else {
      buffer
        ..writeln('`$name`:')
        ..writeln()
        ..writeln(fence)
        ..writeln(currentCode)
        ..writeln('```')
        ..writeln()
        ..write(_instruction);
    }
    return buffer.toString();
  }
}
