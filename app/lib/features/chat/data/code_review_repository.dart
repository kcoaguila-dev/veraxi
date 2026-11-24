import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// One hunk of a file diff from GET /api/v1/sandboxes/sessions/{id}/diff:
/// raw unified-diff [lines] (the first is the `@@ ... @@` header) and
/// the 1-based old/new start lines the header declares.
class CodeReviewHunk {
  final int oldStart;
  final int newStart;
  final List<String> lines;

  const CodeReviewHunk({
    this.oldStart = 1,
    this.newStart = 1,
    this.lines = const [],
  });

  factory CodeReviewHunk.fromJson(Map<String, dynamic> json) {
    return CodeReviewHunk(
      oldStart: (json['old_start'] as num?)?.toInt() ?? 1,
      newStart: (json['new_start'] as num?)?.toInt() ?? 1,
      lines: json['lines'] is List
          ? (json['lines'] as List).map((e) => e.toString()).toList()
          : const [],
    );
  }
}

/// One file's diff in a [CodeReviewDiff].
class CodeReviewDiffFile {
  final String path;
  final String? language;
  final String status;
  final int additions;
  final int deletions;
  final List<CodeReviewHunk> hunks;

  const CodeReviewDiffFile({
    required this.path,
    this.language,
    this.status = 'modified',
    this.additions = 0,
    this.deletions = 0,
    this.hunks = const [],
  });

  factory CodeReviewDiffFile.fromJson(Map<String, dynamic> json) {
    return CodeReviewDiffFile(
      path: json['path'] as String? ?? '',
      language: json['language'] as String?,
      status: json['status'] as String? ?? 'modified',
      additions: (json['additions'] as num?)?.toInt() ?? 0,
      deletions: (json['deletions'] as num?)?.toInt() ?? 0,
      hunks: json['hunks'] is List
          ? (json['hunks'] as List)
              .whereType<Map>()
              .map((h) => CodeReviewHunk.fromJson(Map<String, dynamic>.from(h)))
              .toList()
          : const [],
    );
  }

  /// Bare file name (the part after the last `/`).
  String get fileName => path.contains('/') ? path.split('/').last : path;

  /// Directory portion of [path], or empty for a root-level file.
  String get directory =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
}

/// Response of GET /api/v1/sandboxes/sessions/{id}/diff (Phase 2
/// shape, shared with the chat `files_changed` summary).
class CodeReviewDiff {
  final String sessionId;
  final String turnId;
  final int totalAdditions;
  final int totalDeletions;
  final List<CodeReviewDiffFile> files;

  const CodeReviewDiff({
    this.sessionId = '',
    this.turnId = '',
    this.totalAdditions = 0,
    this.totalDeletions = 0,
    this.files = const [],
  });

  factory CodeReviewDiff.fromJson(Map<String, dynamic> json) {
    final files = json['files'] is List
        ? (json['files'] as List)
            .whereType<Map>()
            .map((f) =>
                CodeReviewDiffFile.fromJson(Map<String, dynamic>.from(f)))
            .toList()
        : const <CodeReviewDiffFile>[];
    return CodeReviewDiff(
      sessionId: json['session_id'] as String? ?? '',
      turnId: json['turn_id'] as String? ?? '',
      totalAdditions: (json['total_additions'] as num?)?.toInt() ??
          files.fold(0, (sum, f) => sum + f.additions),
      totalDeletions: (json['total_deletions'] as num?)?.toInt() ??
          files.fold(0, (sum, f) => sum + f.deletions),
      files: files,
    );
  }
}

final codeReviewRepositoryProvider = Provider<CodeReviewRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return CodeReviewRepository(apiClient: client);
});

/// Authenticated wrapper over the Phase 2 sandbox review endpoints.
///
/// Every call goes through [ApiClient], which attaches the current
/// session token; paths are `/v1/...` because the client's base URL
/// already ends in `/api`.
class CodeReviewRepository {
  final ApiClient apiClient;

  CodeReviewRepository({required this.apiClient});

  String _sessionPath(String sessionId) =>
      '/v1/sandboxes/sessions/${Uri.encodeComponent(sessionId)}';

  /// GET /api/v1/sandboxes/sessions/{id}/diff[?turn_id=...]
  Future<CodeReviewDiff> fetchDiff(String sessionId,
      {String turnId = ''}) async {
    final query =
        turnId.isNotEmpty ? '?turn_id=${Uri.encodeQueryComponent(turnId)}' : '';
    final data = await apiClient.get('${_sessionPath(sessionId)}/diff$query');
    return CodeReviewDiff.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// POST /api/v1/sandboxes/sessions/{id}/files/accept — stages [paths].
  Future<void> acceptFiles(String sessionId, List<String> paths) async {
    await apiClient.post(
      '${_sessionPath(sessionId)}/files/accept',
      body: {'paths': paths},
    );
  }

  /// POST /api/v1/sandboxes/sessions/{id}/files/revert — reverts [paths].
  Future<void> revertFiles(String sessionId, List<String> paths) async {
    await apiClient.post(
      '${_sessionPath(sessionId)}/files/revert',
      body: {'paths': paths},
    );
  }

  /// POST /api/v1/sandboxes/sessions/{id}/hunks/apply — stages or reverts
  /// a single unified-diff hunk.
  Future<void> applyHunk(
    String sessionId,
    String path,
    List<String> lines, {
    required bool accept,
  }) async {
    await apiClient.post(
      '${_sessionPath(sessionId)}/hunks/apply',
      body: {'path': path, 'lines': lines, 'accept': accept},
    );
  }

  /// POST /api/v1/sandboxes/sessions/{id}/commit — commits staged
  /// files with [message]. The backend never pushes.
  Future<void> commit(String sessionId, String message) async {
    await apiClient.post(
      '${_sessionPath(sessionId)}/commit',
      body: {'message': message},
    );
  }

  /// POST /api/v1/vuln/audit-diff — scopes Neo4j reachability and
  /// SAST/secret checks to [files] / [diff].
  Future<Map<String, dynamic>> auditDiff({
    List<String> files = const [],
    String diff = '',
    String? repo,
  }) async {
    final data = await apiClient.post(
      '/v1/vuln/audit-diff',
      body: {
        'files': files,
        'diff': diff,
        if (repo != null && repo.isNotEmpty) 'repo': repo,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }
}
