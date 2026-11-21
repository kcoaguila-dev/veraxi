import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// Content of one indexed code file from GET /api/v1/code/file.
///
/// [source] is what the server actually served: `file` for the
/// complete on-disk file, `excerpt` when only stored text could be
/// returned. [startLine] is the 1-based file line number of the
/// first line in [lines] (1 for a full file; the excerpt's first
/// line otherwise), so the viewer can number lines truthfully.
class CodeFileContent {
  final String path;
  final String source;
  final String content;
  final List<String> lines;
  final int startLine;
  final int endLine;
  final int lineCount;
  final String? language;

  const CodeFileContent({
    required this.path,
    required this.source,
    required this.content,
    required this.lines,
    required this.startLine,
    required this.endLine,
    required this.lineCount,
    this.language,
  });

  factory CodeFileContent.fromJson(Map<String, dynamic> json) {
    final content = json['content'] as String? ?? '';
    final rawLines = content.split('\n');
    // A trailing newline terminates the last line; it does not add
    // an empty one. Drop the split artifact so gutter numbers match
    // the backend's splitlines() count.
    if (rawLines.isNotEmpty && rawLines.last.isEmpty) {
      rawLines.removeLast();
    }
    return CodeFileContent(
      path: json['path'] as String? ?? '',
      source: json['source'] as String? ?? 'file',
      content: content,
      lines: rawLines,
      startLine: (json['start_line'] as num?)?.toInt() ?? 1,
      endLine: (json['end_line'] as num?)?.toInt() ?? rawLines.length,
      lineCount: (json['line_count'] as num?)?.toInt() ?? rawLines.length,
      language: json['language'] as String?,
    );
  }

  /// True when the server returned stored text rather than the
  /// complete file; the viewer badges this honestly as an excerpt.
  bool get isExcerpt => source == 'excerpt';
}

final codeFileRepositoryProvider = Provider<CodeFileRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return CodeFileRepository(apiClient: client);
});

/// Fetches indexed code file content for the citation viewer.
///
/// The backend serves a file only when the signed-in tenant's code
/// graph indexes it; any failure (not indexed, not on the server,
/// offline) throws and the viewer renders its unavailable state.
class CodeFileRepository {
  final ApiClient apiClient;

  CodeFileRepository({required this.apiClient});

  Future<CodeFileContent> fetchFile(String path) async {
    final encoded = Uri.encodeQueryComponent(path);
    final data = await apiClient.get('/v1/code/file?path=$encoded');
    return CodeFileContent.fromJson(Map<String, dynamic>.from(data as Map));
  }
}
