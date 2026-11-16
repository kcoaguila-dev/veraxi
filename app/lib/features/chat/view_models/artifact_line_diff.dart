import 'dart:typed_data';

/// One row of a line-level diff between two versions of an artifact.
enum LineDiffKind { unchanged, added, removed }

class LineDiffEntry {
  final LineDiffKind kind;
  final String text;

  /// 1-based line number in the old text (null for added lines).
  final int? oldLineNumber;

  /// 1-based line number in the new text (null for removed lines).
  final int? newLineNumber;

  const LineDiffEntry({
    required this.kind,
    required this.text,
    this.oldLineNumber,
    this.newLineNumber,
  });

  @override
  bool operator ==(Object other) =>
      other is LineDiffEntry &&
      other.kind == kind &&
      other.text == text &&
      other.oldLineNumber == oldLineNumber &&
      other.newLineNumber == newLineNumber;

  @override
  int get hashCode => Object.hash(kind, text, oldLineNumber, newLineNumber);
}

/// Above this many lines per side, [computeLineDiff] skips the full LCS
/// table (quadratic memory) and falls back to trimming the common
/// prefix/suffix, treating everything between as removed-then-added.
const int _lcsLineLimit = 1500;

List<String> _splitLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  // A trailing newline terminates the last line; it is not an extra
  // empty line of its own.
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// Computes a line-level diff between [oldText] and [newText], the way
/// the artifact panel shows what changed between two versions: shared
/// lines in order, removals before the additions that replace them.
List<LineDiffEntry> computeLineDiff(String oldText, String newText) {
  final oldLines = _splitLines(oldText);
  final newLines = _splitLines(newText);
  if (oldLines.length > _lcsLineLimit || newLines.length > _lcsLineLimit) {
    return _prefixSuffixDiff(oldLines, newLines);
  }
  return _lcsDiff(oldLines, newLines);
}

List<LineDiffEntry> _lcsDiff(List<String> oldLines, List<String> newLines) {
  final m = oldLines.length;
  final n = newLines.length;
  // lengths[i][j] = LCS length of oldLines[i..] and newLines[j..],
  // stored as a flat (m + 1) x (n + 1) table.
  final width = n + 1;
  final lengths = Int32List((m + 1) * width);
  for (var i = m - 1; i >= 0; i--) {
    for (var j = n - 1; j >= 0; j--) {
      if (oldLines[i] == newLines[j]) {
        lengths[i * width + j] = lengths[(i + 1) * width + j + 1] + 1;
      } else {
        final down = lengths[(i + 1) * width + j];
        final right = lengths[i * width + j + 1];
        lengths[i * width + j] = down >= right ? down : right;
      }
    }
  }

  final entries = <LineDiffEntry>[];
  var i = 0;
  var j = 0;
  while (i < m && j < n) {
    if (oldLines[i] == newLines[j]) {
      entries.add(LineDiffEntry(
        kind: LineDiffKind.unchanged,
        text: oldLines[i],
        oldLineNumber: i + 1,
        newLineNumber: j + 1,
      ));
      i++;
      j++;
    } else if (lengths[(i + 1) * width + j] >= lengths[i * width + j + 1]) {
      entries.add(LineDiffEntry(
        kind: LineDiffKind.removed,
        text: oldLines[i],
        oldLineNumber: i + 1,
      ));
      i++;
    } else {
      entries.add(LineDiffEntry(
        kind: LineDiffKind.added,
        text: newLines[j],
        newLineNumber: j + 1,
      ));
      j++;
    }
  }
  while (i < m) {
    entries.add(LineDiffEntry(
      kind: LineDiffKind.removed,
      text: oldLines[i],
      oldLineNumber: i + 1,
    ));
    i++;
  }
  while (j < n) {
    entries.add(LineDiffEntry(
      kind: LineDiffKind.added,
      text: newLines[j],
      newLineNumber: j + 1,
    ));
    j++;
  }
  return entries;
}

List<LineDiffEntry> _prefixSuffixDiff(
  List<String> oldLines,
  List<String> newLines,
) {
  var prefix = 0;
  while (prefix < oldLines.length &&
      prefix < newLines.length &&
      oldLines[prefix] == newLines[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < oldLines.length - prefix &&
      suffix < newLines.length - prefix &&
      oldLines[oldLines.length - 1 - suffix] ==
          newLines[newLines.length - 1 - suffix]) {
    suffix++;
  }

  final entries = <LineDiffEntry>[];
  for (var i = 0; i < prefix; i++) {
    entries.add(LineDiffEntry(
      kind: LineDiffKind.unchanged,
      text: oldLines[i],
      oldLineNumber: i + 1,
      newLineNumber: i + 1,
    ));
  }
  for (var i = prefix; i < oldLines.length - suffix; i++) {
    entries.add(LineDiffEntry(
      kind: LineDiffKind.removed,
      text: oldLines[i],
      oldLineNumber: i + 1,
    ));
  }
  for (var j = prefix; j < newLines.length - suffix; j++) {
    entries.add(LineDiffEntry(
      kind: LineDiffKind.added,
      text: newLines[j],
      newLineNumber: j + 1,
    ));
  }
  for (var s = 0; s < suffix; s++) {
    final oldIndex = oldLines.length - suffix + s;
    final newIndex = newLines.length - suffix + s;
    entries.add(LineDiffEntry(
      kind: LineDiffKind.unchanged,
      text: oldLines[oldIndex],
      oldLineNumber: oldIndex + 1,
      newLineNumber: newIndex + 1,
    ));
  }
  return entries;
}
