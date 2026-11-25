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

  /// Prompt of the turn under review, when the opener knows it (the
  /// Phase 5 review pane's "For Turn" bar shows it; otherwise it
  /// falls back to the turn id).
  final String? turnPrompt;

  const CodeReviewState({
    required this.sessionId,
    required this.turnId,
    this.focusedPath,
    this.focusedStartLine,
    this.focusedEndLine,
    this.files = const [],
    this.turnPrompt,
  });

  /// True when [sessionId] names a live sandbox session whose diff /
  /// accept / revert / commit endpoints can be called. A review
  /// opened from a citation carries an empty session id and is
  /// read-only (Phase 5 decision b): the pane must hide every git
  /// action rather than render dead buttons.
  bool get hasLiveSandbox => sessionId.isNotEmpty;

  CodeReviewState copyWith({
    String? sessionId,
    String? turnId,
    String? focusedPath,
    bool clearFocus = false,
    int? focusedStartLine,
    int? focusedEndLine,
    List<CodeReviewFileSummary>? files,
    String? turnPrompt,
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
      turnPrompt: turnPrompt ?? this.turnPrompt,
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
  bool _userChanged = false;

  @override
  String build() {
    _userChanged = false;
    Future.microtask(() => _loadSaved());
    return 'Medium';
  }

  Future<void> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(storageKey);
      if (!_userChanged && saved != null && levels.contains(saved)) {
        state = saved;
      }
    } catch (_) {
      // Ignore SharedPreferences errors in tests/headless environments.
    }
  }

  Future<void> setLevel(String level) async {
    if (!levels.contains(level)) return;
    _userChanged = true;
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

/// Branch the Code composer is scoped to. No branch-list endpoint
/// exists yet, so this holds the welded tray's selection (`main`
/// until a repo reports known branches) and is stamped onto Code
/// thread sends as the request `branch`.
final codeBranchProvider = StateProvider<String>((ref) => 'main');

/// Whether the next Code thread should isolate edits in a new git worktree.
final codeWorktreeProvider = StateProvider<bool>((ref) => false);

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

/// Diff hunk attached from the Diff Review pane to the single bottom-center
/// Code Thread composer.
class DiffHunkAttachment {
  final String file;
  final int line;
  final String hunkText;

  const DiffHunkAttachment({
    required this.file,
    required this.line,
    required this.hunkText,
  });

  String get chipLabel => '$file:$line';

  @override
  bool operator ==(Object other) =>
      other is DiffHunkAttachment &&
      other.file == file &&
      other.line == line &&
      other.hunkText == hunkText;

  @override
  int get hashCode => Object.hash(file, line, hunkText);
}

/// Currently attached diff hunk for the Code Thread composer.
final attachedDiffHunkProvider =
    StateProvider<DiffHunkAttachment?>((ref) => null);

/// Pre-seeded security fix prompt handed off from Security → Code Thread.
final pendingSecurityThreadPromptProvider =
    StateProvider<String?>((ref) => null);

/// Default split-pane width fraction for [CodeReviewDrawer] on desktop.
const double kDefaultReviewPaneFraction = 0.55;

/// Expanded split-pane width fraction for [CodeReviewDrawer] on desktop.
const double kExpandedReviewPaneFraction = 0.78;

/// User-adjusted desktop split-pane width fraction for [CodeReviewDrawer],
/// shared across Chat Mode and Code Mode.
final reviewPaneWidthFractionProvider =
    StateProvider<double>((ref) => kDefaultReviewPaneFraction);

/// Computes the clamped pixel width for the desktop [CodeReviewDrawer]
/// split-pane so neither the review drawer nor the left workspace collapses.
double computeReviewPaneWidth(
  double totalWidth,
  double fraction, {
  double minWidth = 380.0,
  double minRemainingWidth = 360.0,
}) {
  final maxAllowed =
      (totalWidth - minRemainingWidth).clamp(minWidth, totalWidth);
  return (totalWidth * fraction).clamp(minWidth, maxAllowed);
}
