import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Top-level workspace mode in the unified `[ Chat | Code ]` shell.
enum WorkspaceMode { chat, code }

/// Sub-views surfaced inside the Code workbench tab.
enum CodeSubView {
  vulnIntel,
  repoXray,
  securityFeed,
  corpusBriefing,
  dbtLineage,
}

/// Summary of an indexed repository rendered in the Code sidebar.
class IndexedRepoItem {
  final String repoKey;
  final String displayName;
  final String? rootPath;
  final int fileCount;
  final int symbolCount;
  final bool isStale;

  const IndexedRepoItem({
    required this.repoKey,
    required this.displayName,
    this.rootPath,
    required this.fileCount,
    required this.symbolCount,
    this.isStale = false,
  });

  String get subtitle => '$fileCount files · $symbolCount symbols';

  factory IndexedRepoItem.fromJson(Map<String, dynamic> json) {
    final key = json['repo_key'] as String? ?? '';
    return IndexedRepoItem(
      repoKey: key,
      displayName: json['display_name'] as String? ?? key,
      rootPath: json['root_path'] as String?,
      fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
      symbolCount: (json['symbol_count'] as num?)?.toInt() ?? 0,
      isStale: json['is_stale'] as bool? ?? false,
    );
  }
}

/// Active ingestion job shown in the Knowledge Hub left rail queue.
class IngestionQueueItem {
  final String jobId;
  final String source;
  final String stage;
  final double progress;

  const IngestionQueueItem({
    required this.jobId,
    required this.source,
    required this.stage,
    this.progress = 0.0,
  });
}

/// Active workspace mode (`Chat` vs `Code`), preserved across tab switches.
final workspaceModeProvider =
    StateProvider<WorkspaceMode>((ref) => WorkspaceMode.chat);

/// Active sub-view inside `Code` mode.
final codeSubViewProvider =
    StateProvider<CodeSubView>((ref) => CodeSubView.vulnIntel);

/// Number of active CISA KEV alerts surfaced as a sidebar indicator dot/pill.
final activeKevCountProvider = StateProvider<int>((ref) => 0);

/// Currently scoped indexed repository key in the Code sidebar.
final selectedIndexedRepoProvider = StateProvider<String?>((ref) => null);

/// Live indexed repositories for the Code sidebar, populated from
/// `/api/v1/code/repos`.
final indexedReposProvider =
    StateProvider<List<IndexedRepoItem>>((ref) => const []);

/// Live ingestion queue items shared with the Knowledge Hub left rail.
final ingestionQueueProvider =
    StateProvider<List<IngestionQueueItem>>((ref) => const []);
