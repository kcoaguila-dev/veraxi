import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/core/auth/oauth_popup.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/chat/data/connect_repo_repository.dart';

export 'package:veraxi_app/features/chat/data/connect_repo_repository.dart'
    show GitHubAppInstallation, GitHubAppRepoItem, GitHubAppStatus;

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
  final bool githubAppLoading;
  final bool githubAppAuthorizing;
  final GitHubAppStatus? githubAppStatus;
  final List<GitHubAppRepoItem> githubAppRepos;
  final GitHubAppRepoItem? selectedGitHubAppRepo;
  final String githubAppSearchQuery;
  final bool autoSyncOnPush;

  /// Creates a [ConnectRepoState].
  const ConnectRepoState({
    this.indexing = false,
    this.activeTarget,
    this.statusMessage,
    this.errorMessage,
    this.githubAppLoading = false,
    this.githubAppAuthorizing = false,
    this.githubAppStatus,
    this.githubAppRepos = const [],
    this.selectedGitHubAppRepo,
    this.githubAppSearchQuery = '',
    this.autoSyncOnPush = true,
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
    bool? githubAppLoading,
    bool? githubAppAuthorizing,
    GitHubAppStatus? githubAppStatus,
    List<GitHubAppRepoItem>? githubAppRepos,
    GitHubAppRepoItem? selectedGitHubAppRepo,
    bool clearSelectedGitHubAppRepo = false,
    String? githubAppSearchQuery,
    bool? autoSyncOnPush,
  }) {
    return ConnectRepoState(
      indexing: indexing ?? this.indexing,
      activeTarget:
          clearActiveTarget ? null : (activeTarget ?? this.activeTarget),
      statusMessage: clearStatus ? null : (statusMessage ?? this.statusMessage),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      githubAppLoading: githubAppLoading ?? this.githubAppLoading,
      githubAppAuthorizing: githubAppAuthorizing ?? this.githubAppAuthorizing,
      githubAppStatus: githubAppStatus ?? this.githubAppStatus,
      githubAppRepos: githubAppRepos ?? this.githubAppRepos,
      selectedGitHubAppRepo: clearSelectedGitHubAppRepo
          ? null
          : (selectedGitHubAppRepo ?? this.selectedGitHubAppRepo),
      githubAppSearchQuery: githubAppSearchQuery ?? this.githubAppSearchQuery,
      autoSyncOnPush: autoSyncOnPush ?? this.autoSyncOnPush,
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

  /// Loads GitHub App configuration, connected installations, and granted repos.
  Future<void> loadGitHubApp() async {
    state = state.copyWith(githubAppLoading: true, clearError: true);
    try {
      final status = await _repository.fetchGitHubAppStatus();
      var repos = const <GitHubAppRepoItem>[];
      if (status.configured && status.isConnected) {
        repos = await _repository.fetchGitHubAppRepos(
          query: state.githubAppSearchQuery,
        );
      }
      state = state.copyWith(
        githubAppLoading: false,
        githubAppStatus: status,
        githubAppRepos: repos,
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        githubAppLoading: false,
        errorMessage: 'Failed to load GitHub App status.',
      );
    }
  }

  /// Updates the search filter for granted GitHub App repositories.
  void setGitHubAppSearchQuery(String query) {
    state = state.copyWith(githubAppSearchQuery: query);
  }

  /// Selects a [repo] in the GitHub App picker.
  void selectGitHubAppRepo(GitHubAppRepoItem repo) {
    state = state.copyWith(
      selectedGitHubAppRepo: repo,
      autoSyncOnPush: repo.autoSyncOnPush,
      clearError: true,
    );
  }

  /// Toggles automatic incremental re-indexing on `git push` webhooks.
  void setAutoSyncOnPush(bool enabled) {
    state = state.copyWith(autoSyncOnPush: enabled);
  }

  /// Launches the GitHub App installation + selected-repos OAuth popup.
  Future<void> connectGitHubApp() async {
    state = state.copyWith(githubAppAuthorizing: true, clearError: true);
    try {
      final url = await _repository.startGitHubAppInstall();
      if (url.isEmpty) {
        state = state.copyWith(
          githubAppAuthorizing: false,
          errorMessage: 'GitHub App install URL was empty.',
        );
        return;
      }
      final popupResult = await launchOAuthPopup(url, 'github_app');
      if (popupResult == null) {
        final uri = Uri.tryParse(url);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        state = state.copyWith(githubAppAuthorizing: false);
        return;
      }
      state = state.copyWith(githubAppAuthorizing: false);
      if (popupResult.completed) {
        await loadGitHubApp();
      } else if (popupResult.pending) {
        state = state.copyWith(
          statusMessage:
              'Approval requested from your GitHub organization admin.',
        );
      } else if (popupResult.error != null) {
        state = state.copyWith(
          errorMessage:
              'GitHub App authorization failed (${popupResult.error}).',
        );
      } else {
        // User closed popup or GitHub COOP severed window.opener — refresh
        // status so newly completed installs still appear.
        await loadGitHubApp();
      }
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        githubAppAuthorizing: false,
        errorMessage: 'Could not launch GitHub App installation.',
      );
    }
  }

  /// Opens GitHub's native repository-selection settings in a popup (with
  /// external-tab fallback) and refreshes granted repos on return.
  Future<void> openManageGitHubRepos() async {
    final manageUrl = state.githubAppStatus?.manageUrl ?? '';
    if (manageUrl.isEmpty) return;
    try {
      final popupResult = await launchOAuthPopup(manageUrl, 'github_app');
      if (popupResult == null) {
        final uri = Uri.tryParse(manageUrl);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        return;
      }
      await loadGitHubApp();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
    }
  }

  /// Disconnects and purges an indexed GitHub App [repo] from Neo4j, Qdrant,
  /// and Supabase, then refreshes the indexed and granted repo lists.
  Future<void> disconnectGitHubAppRepo(GitHubAppRepoItem repo) async {
    final parts = repo.fullName.split('/');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      state = state.copyWith(
        errorMessage: 'Invalid GitHub repository name: ${repo.fullName}',
      );
      return;
    }

    state = state.copyWith(clearError: true, clearStatus: true);
    try {
      await _repository.disconnectGitHubAppRepo(parts[0], parts[1]);
      final repos = await _repository.fetchIndexedRepos();
      _ref.read(indexedReposProvider.notifier).state = repos;
      if (_ref.read(selectedIndexedRepoProvider) == repo.fullName) {
        _ref.read(selectedIndexedRepoProvider.notifier).state = null;
      }
      final clearSelected =
          state.selectedGitHubAppRepo?.fullName == repo.fullName;
      state = state.copyWith(
        clearSelectedGitHubAppRepo: clearSelected,
        statusMessage: 'Disconnected ${repo.fullName}',
      );
      await loadGitHubApp();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        errorMessage: 'Failed to disconnect ${repo.fullName}.',
      );
    }
  }

  /// Triggers non-blocking zero-retention indexing for [repo].
  Future<void> startGitHubAppIndexing(GitHubAppRepoItem repo) async {
    state = state.copyWith(
      indexing: true,
      activeTarget: repo.fullName,
      clearStatus: true,
      clearError: true,
    );

    try {
      final response = await _repository.indexGitHubAppRepo(
        installationId: repo.installationId,
        repoFullName: repo.fullName,
        branch: repo.defaultBranch,
        autoSyncOnPush: state.autoSyncOnPush,
      );
      Map<String, dynamic> finalResult = response;
      if (response['status'] == 'queued' && response['job_id'] != null) {
        finalResult = await _pollJobUntilDone(response['job_id'].toString());
      }
      final repos = await _repository.fetchIndexedRepos();
      _ref.read(indexedReposProvider.notifier).state = repos;
      _ref.read(selectedIndexedRepoProvider.notifier).state = repo.fullName;

      final nodes = finalResult['nodes_written'] ?? 0;
      final edges = finalResult['edges_written'] ?? 0;
      state = state.copyWith(
        indexing: false,
        statusMessage: 'Indexed ${repo.fullName} ($nodes nodes · $edges edges)',
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        indexing: false,
        errorMessage: 'GitHub App indexing failed for ${repo.fullName}.',
      );
    }
  }

  Future<Map<String, dynamic>> _pollJobUntilDone(String jobId) async {
    for (var attempt = 0; attempt < 60; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final job = await _repository.pollGitHubAppJob(jobId);
      final status = job['status'] as String? ?? '';
      if (status == 'complete') {
        final res = job['result'];
        return res is Map<String, dynamic> ? res : <String, dynamic>{};
      }
      if (status == 'failed') {
        throw StateError(
          job['error']?.toString() ?? 'GitHub App indexing job failed',
        );
      }
      if (status == 'not_found') {
        throw StateError('GitHub App indexing job disappeared');
      }
    }
    throw TimeoutException('GitHub App indexing timed out');
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
      return 'Remote cloning is not enabled on this server yet — use the GitHub App tab or pass a local workspace path.';
    }
    return 'Indexing failed — check that the path exists inside an allowed workspace root.';
  }
}
