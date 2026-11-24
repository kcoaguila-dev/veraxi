import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/chat/data/connect_repo_repository.dart';

/// Source tab options inside the Connect Repository modal.
enum ConnectRepoSourceTab {
  localPath,
  gitUrl,
  githubApp,
}

/// Non-blocking repository indexing state observed by the Connect
/// Repository modal and Code Chat tray.
class ConnectRepoState {
  final bool indexing;
  final String? activeTarget;
  final String? statusMessage;
  final String? errorMessage;

  /// Creates a [ConnectRepoState].
  const ConnectRepoState({
    this.indexing = false,
    this.activeTarget,
    this.statusMessage,
    this.errorMessage,
  });

  /// Returns a copy with updated fields.
  ConnectRepoState copyWith({
    bool? indexing,
    String? activeTarget,
    bool clearActiveTarget = false,
    String? statusMessage,
    bool clearStatus = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ConnectRepoState(
      indexing: indexing ?? this.indexing,
      activeTarget:
          clearActiveTarget ? null : (activeTarget ?? this.activeTarget),
      statusMessage: clearStatus ? null : (statusMessage ?? this.statusMessage),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Provider for [ConnectRepoViewModel].
final connectRepoViewModelProvider =
    StateNotifierProvider<ConnectRepoViewModel, ConnectRepoState>((ref) {
  final repository = ref.watch(connectRepoRepositoryProvider);
  return ConnectRepoViewModel(repository: repository, ref: ref);
});

/// ViewModel handling non-blocking repository indexing and selection
/// from Code Chat without navigating away from the active thread.
class ConnectRepoViewModel extends StateNotifier<ConnectRepoState> {
  final ConnectRepoRepository _repository;
  final Ref _ref;

  /// Creates a [ConnectRepoViewModel].
  ConnectRepoViewModel({
    required ConnectRepoRepository repository,
    required Ref ref,
  })  : _repository = repository,
        _ref = ref,
        super(const ConnectRepoState());

  /// Selects an already-indexed [repo] as the active Code Chat scope.
  void selectExistingRepo(IndexedRepoItem repo) {
    _ref.read(selectedIndexedRepoProvider.notifier).state = repo.repoKey;
    state = state.copyWith(
      clearError: true,
      statusMessage: 'Scoped to ${repo.displayName}',
    );
  }

  /// Clears any status or error banner shown in the Code Chat tray.
  void clearBanner() {
    state = state.copyWith(
      clearActiveTarget: true,
      clearStatus: true,
      clearError: true,
    );
  }

  /// Starts GraphRAG indexing for [rawPath] in the background, updates
  /// [indexedReposProvider], and auto-selects the newly indexed repo.
  Future<void> startIndexing(String rawPath) async {
    final path = rawPath.trim();
    if (path.isEmpty) {
      state = state.copyWith(errorMessage: 'Enter a repository path first');
      return;
    }

    state = state.copyWith(
      indexing: true,
      activeTarget: _displayTarget(path),
      clearStatus: true,
      clearError: true,
    );

    try {
      final result = await _repository.ingestRepo(path);
      final repos = await _repository.fetchIndexedRepos();
      _ref.read(indexedReposProvider.notifier).state = repos;
      _autoSelectNewestRepo(repos, path);

      final nodes = result['nodes_written'] ?? 0;
      final edges = result['edges_written'] ?? 0;
      state = state.copyWith(
        indexing: false,
        statusMessage: 'Indexed $nodes nodes · $edges edges',
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        indexing: false,
        errorMessage: _friendlyError(path),
      );
    }
  }

  void _autoSelectNewestRepo(List<IndexedRepoItem> repos, String path) {
    if (repos.isEmpty) return;
    final matched = repos.where((r) => r.rootPath == path).toList();
    final chosen = matched.isNotEmpty ? matched.first : repos.first;
    _ref.read(selectedIndexedRepoProvider.notifier).state = chosen.repoKey;
  }

  String _displayTarget(String path) {
    final trimmed = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final idx = trimmed.lastIndexOf('/');
    return idx >= 0 && idx < trimmed.length - 1
        ? trimmed.substring(idx + 1)
        : trimmed;
  }

  String _friendlyError(String path) {
    if (path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('git@')) {
      return 'Remote cloning is not enabled on this server yet — clone locally and pass the workspace path.';
    }
    return 'Indexing failed — check that the path exists inside an allowed workspace root.';
  }
}
