import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Top-level workspace mode in the unified `[ Chat | Code ]` shell.
enum WorkspaceMode { chat, code }

/// Sub-views surfaced inside the Code workbench tab.
///
/// [codeChat] is appended last on purpose: the existing values keep the
/// indices the Code workbench `IndexedStack` was built against.
enum CodeSubView {
  vulnIntel,
  repoXray,
  securityFeed,
  corpusBriefing,
  dbtLineage,
  codeChat,
}

/// Whether the Code composer plans (read-only tool surface) or acts
/// (full sandbox tool surface) — mirrors the backend `execution_mode`.
enum CodeExecutionMode {
  plan,
  act;

  /// Storage value used in SharedPreferences.
  String get storageValue => name;

  /// Parse a stored value; anything unrecognised falls back to [act]
  /// rather than failing.
  static CodeExecutionMode fromStorage(String? value) {
    for (final mode in CodeExecutionMode.values) {
      if (mode.name == value) return mode;
    }
    return CodeExecutionMode.act;
  }
}

/// Sources a Code thread is scoped to: indexed repositories plus
/// individual Knowledge Hub documents.
class CodeSelectedSources {
  final Set<String> repoKeys;
  final Set<String> docIds;

  const CodeSelectedSources({
    this.repoKeys = const {},
    this.docIds = const {},
  });

  bool get isEmpty => repoKeys.isEmpty && docIds.isEmpty;

  CodeSelectedSources copyWith({
    Set<String>? repoKeys,
    Set<String>? docIds,
  }) {
    return CodeSelectedSources(
      repoKeys: repoKeys ?? this.repoKeys,
      docIds: docIds ?? this.docIds,
    );
  }

  CodeSelectedSources toggleRepoKey(String repoKey) {
    final updated = {...repoKeys};
    if (!updated.remove(repoKey)) updated.add(repoKey);
    return copyWith(repoKeys: updated);
  }

  CodeSelectedSources toggleDocId(String docId) {
    final updated = {...docIds};
    if (!updated.remove(docId)) updated.add(docId);
    return copyWith(docIds: updated);
  }
}

/// One file entry in an active Code review session's changed-files list.
class CodeReviewFileSummary {
  final String path;
  final int additions;
  final int deletions;

  const CodeReviewFileSummary({
    required this.path,
    this.additions = 0,
    this.deletions = 0,
  });
}

/// Focus state for an in-progress Code review session, consumed by the
/// review split-pane in later phases: which session/turn is under
/// review, which file (and line range) is focused, and the
/// changed-files summary for that turn.
class CodeReviewState {
  final String sessionId;
  final String turnId;
  final String? focusedPath;
  final int? focusedStartLine;
  final int? focusedEndLine;
  final List<CodeReviewFileSummary> files;

  const CodeReviewState({
    required this.sessionId,
    required this.turnId,
    this.focusedPath,
    this.focusedStartLine,
    this.focusedEndLine,
    this.files = const [],
  });

  CodeReviewState copyWith({
    String? sessionId,
    String? turnId,
    String? focusedPath,
    bool clearFocus = false,
    int? focusedStartLine,
    int? focusedEndLine,
    List<CodeReviewFileSummary>? files,
  }) {
    return CodeReviewState(
      sessionId: sessionId ?? this.sessionId,
      turnId: turnId ?? this.turnId,
      focusedPath: clearFocus ? null : (focusedPath ?? this.focusedPath),
      focusedStartLine:
          clearFocus ? null : (focusedStartLine ?? this.focusedStartLine),
      focusedEndLine:
          clearFocus ? null : (focusedEndLine ?? this.focusedEndLine),
      files: files ?? this.files,
    );
  }
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

/// Active sub-view inside `Code` mode. Defaults to the Code chat
/// surface; the intel/analysis panels are reached from it.
final codeSubViewProvider =
    StateProvider<CodeSubView>((ref) => CodeSubView.codeChat);

/// Thinking level for Code threads (`Low` / `Medium` / `High`),
/// persisted via SharedPreferences under `code_thinking_level`.
final codeThinkingLevelProvider =
    NotifierProvider<CodeThinkingLevelNotifier, String>(
  () => CodeThinkingLevelNotifier(),
);

class CodeThinkingLevelNotifier extends Notifier<String> {
  static const String storageKey = 'code_thinking_level';
  static const List<String> levels = ['Low', 'Medium', 'High'];

  @override
  String build() {
    Future.microtask(() => _loadSaved());
    return 'Medium';
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(storageKey);
    if (saved != null && levels.contains(saved)) {
      state = saved;
    }
  }

  Future<void> setLevel(String level) async {
    if (!levels.contains(level)) return;
    state = level;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, level);
  }
}

/// Execution mode for Code threads (plan vs act). Defaults to act.
final codeExecutionModeProvider =
    StateProvider<CodeExecutionMode>((ref) => CodeExecutionMode.act);

/// Sandbox autonomy tier for Code threads, using the backend
/// `autonomy_mode` values (`ask_all`, `auto_read_test`,
/// `auto_workspace_writes`, `autonomous`). Defaults to
/// `auto_read_test`.
final codeAutonomyModeProvider =
    StateProvider<String>((ref) => 'auto_read_test');

/// Sources the next Code thread is scoped to (repo keys + doc ids).
final codeSelectedSourcesProvider =
    StateProvider<CodeSelectedSources>((ref) => const CodeSelectedSources());

/// Active Code review session focus, or null when no review is open.
final activeReviewSessionProvider =
    StateProvider<CodeReviewState?>((ref) => null);

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
