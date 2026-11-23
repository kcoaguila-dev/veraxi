import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/data/code_file_repository.dart';

// Re-export the model so views can import it from the ViewModel layer
// without violating the views → view_models → data dependency contract.
export 'package:veraxi_app/features/chat/data/code_file_repository.dart'
    show CodeFileContent, CodeFileListEntry;

/// A line-anchored code citation target, parsed from a `file://`
/// citation URL of the form `file://<path>#L<start>` or
/// `file://<path>#L<start>-L<end>` — the shape the Repo X-Ray tools
/// emit for code hits.
///
/// Only URLs carrying a line anchor produce a target; plain
/// `file://` document citations and `#page=` anchors return null
/// from [tryParse] and keep their historical external-launch
/// behavior.
class CodeCitationTarget {
  final String path;
  final int startLine;
  final int? endLine;

  const CodeCitationTarget({
    required this.path,
    required this.startLine,
    this.endLine,
  });

  static final RegExp _lineAnchorUrlRegex =
      RegExp(r'^file://(.+)#L(\d+)(?:-L(\d+))?$');

  /// Parse [url] into a target, or null when it is not a
  /// line-anchored code citation.
  static CodeCitationTarget? tryParse(String url) {
    final match = _lineAnchorUrlRegex.firstMatch(url.trim());
    if (match == null) return null;
    final path = match.group(1)!;
    if (path.isEmpty) return null;
    final start = int.tryParse(match.group(2)!);
    if (start == null || start < 1) return null;
    final endRaw = match.group(3);
    final end = endRaw != null ? int.tryParse(endRaw) : null;
    if (endRaw != null && (end == null || end < start)) return null;
    return CodeCitationTarget(path: path, startLine: start, endLine: end);
  }

  /// The last cited line (the start line for single-line anchors).
  int get effectiveEndLine => endLine ?? startLine;

  @override
  bool operator ==(Object other) =>
      other is CodeCitationTarget &&
      other.path == path &&
      other.startLine == startLine &&
      other.endLine == endLine;

  @override
  int get hashCode => Object.hash(path, startLine, endLine);
}

/// Content for the citation viewer, keyed by the citation target.
///
/// Loads through [CodeFileRepository]; an error (file not indexed
/// for this tenant, not present on the server, offline) surfaces as
/// the provider's error state, which the viewer renders as its
/// unavailable state rather than inventing content.
final codeFileProvider = FutureProvider.autoDispose
    .family<CodeFileContent, CodeCitationTarget>((ref, target) {
  final repository = ref.watch(codeFileRepositoryProvider);
  return repository.fetchFile(target.path);
});

/// Indexed-file search for the Code composer's `@` picker, backed by
/// GET /api/v1/code/files. The family key is a record so each
/// (repo, query) pair caches independently while typing.
final codeFileSearchProvider = FutureProvider.autoDispose
    .family<List<CodeFileListEntry>, ({String? repoKey, String query})>(
        (ref, args) {
  final repository = ref.watch(codeFileRepositoryProvider);
  return repository.searchFiles(repoKey: args.repoKey, query: args.query);
});
