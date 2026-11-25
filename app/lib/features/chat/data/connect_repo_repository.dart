import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';

/// Provider for [ConnectRepoRepository].
final connectRepoRepositoryProvider = Provider<ConnectRepoRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return ConnectRepoRepository(apiClient: client);
});

/// One verified GitHub App installation bound to the current tenant.
class GitHubAppInstallation {
  final int installationId;
  final String accountLogin;
  final String accountType;
  final String repositorySelection;
  final String status;

  const GitHubAppInstallation({
    required this.installationId,
    required this.accountLogin,
    required this.accountType,
    required this.repositorySelection,
    required this.status,
  });

  factory GitHubAppInstallation.fromJson(Map<String, dynamic> json) {
    return GitHubAppInstallation(
      installationId: (json['installation_id'] as num?)?.toInt() ?? 0,
      accountLogin: json['account_login'] as String? ?? '',
      accountType: json['account_type'] as String? ?? 'User',
      repositorySelection:
          json['repository_selection'] as String? ?? 'selected',
      status: json['status'] as String? ?? 'active',
    );
  }
}

/// Server-reported GitHub App configuration and installation status.
class GitHubAppStatus {
  final bool configured;
  final String appSlug;
  final String manageUrl;
  final List<GitHubAppInstallation> installations;

  const GitHubAppStatus({
    required this.configured,
    required this.appSlug,
    required this.manageUrl,
    required this.installations,
  });

  bool get isConnected => installations.any((i) => i.status == 'active');

  factory GitHubAppStatus.fromJson(Map<String, dynamic> json) {
    final rawInstalls = json['installations'] as List<dynamic>? ?? const [];
    return GitHubAppStatus(
      configured: json['configured'] as bool? ?? false,
      appSlug: json['app_slug'] as String? ?? '',
      manageUrl: json['manage_url'] as String? ?? '',
      installations: rawInstalls
          .whereType<Map>()
          .map(
            (e) => GitHubAppInstallation.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(),
    );
  }
}

/// One repository granted to a verified GitHub App installation.
class GitHubAppRepoItem {
  final int installationId;
  final String accountLogin;
  final String fullName;
  final String defaultBranch;
  final bool isPrivate;
  final String indexStatus;
  final bool autoSyncOnPush;
  final String? lastIndexedSha;

  const GitHubAppRepoItem({
    required this.installationId,
    required this.accountLogin,
    required this.fullName,
    required this.defaultBranch,
    required this.isPrivate,
    required this.indexStatus,
    required this.autoSyncOnPush,
    this.lastIndexedSha,
  });

  bool get isIndexed => indexStatus == 'indexed';
  bool get isIndexing => indexStatus == 'indexing';

  factory GitHubAppRepoItem.fromJson(Map<String, dynamic> json) {
    return GitHubAppRepoItem(
      installationId: (json['installation_id'] as num?)?.toInt() ?? 0,
      accountLogin: json['account_login'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      defaultBranch: json['default_branch'] as String? ?? 'main',
      isPrivate: json['private'] as bool? ?? true,
      indexStatus: json['index_status'] as String? ?? 'available',
      autoSyncOnPush: json['auto_sync_on_push'] as bool? ?? true,
      lastIndexedSha: json['last_indexed_sha'] as String?,
    );
  }
}

/// Data repository for indexing repositories and listing indexed repos
/// from the Code Chat Connect Repository modal.
class ConnectRepoRepository {
  final ApiClient apiClient;

  /// Creates a [ConnectRepoRepository] backed by [apiClient].
  ConnectRepoRepository({required this.apiClient});

  /// Triggers GraphRAG code-graph indexing for [repoPath] via
  /// `POST /api/v1/code/ingest`.
  Future<Map<String, dynamic>> ingestRepo(String repoPath) async {
    final data = await apiClient.post(
      '/v1/code/ingest',
      body: {'repo_path': repoPath},
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Fetches the tenant's indexed repositories via `GET /api/v1/code/repos`.
  Future<List<IndexedRepoItem>> fetchIndexedRepos() async {
    final data = await apiClient.get('/v1/code/repos');
    final raw = (data as Map)['repos'] as List<dynamic>? ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => IndexedRepoItem.fromJson(Map<String, dynamic>.from(e)))
        .where((item) => item.repoKey.isNotEmpty)
        .toList();
  }

  /// Fetches server configuration & connected GitHub App installations.
  Future<GitHubAppStatus> fetchGitHubAppStatus() async {
    final data = await apiClient.get('/v1/github-app/status');
    return GitHubAppStatus.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Starts a GitHub App installation + user OAuth flow.
  Future<String> startGitHubAppInstall() async {
    final data = await apiClient.get('/v1/github-app/install/start');
    return (data as Map)['authorization_url'] as String? ?? '';
  }

  /// Lists repositories accessible to the tenant's GitHub App installations.
  Future<List<GitHubAppRepoItem>> fetchGitHubAppRepos({
    String? query,
  }) async {
    final encoded = (query != null && query.trim().isNotEmpty)
        ? '?q=${Uri.encodeQueryComponent(query.trim())}'
        : '';
    final data = await apiClient.get('/v1/github-app/repos$encoded');
    final raw = (data as Map)['repos'] as List<dynamic>? ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => GitHubAppRepoItem.fromJson(Map<String, dynamic>.from(e)))
        .where((item) => item.fullName.isNotEmpty)
        .toList();
  }

  /// Triggers zero-retention ephemeral indexing for a GitHub App repository.
  Future<Map<String, dynamic>> indexGitHubAppRepo({
    required int installationId,
    required String repoFullName,
    String? branch,
    bool autoSyncOnPush = true,
  }) async {
    final data = await apiClient.post(
      '/v1/github-app/index',
      body: {
        'installation_id': installationId,
        'repo_full_name': repoFullName,
        if (branch != null && branch.isNotEmpty) 'branch': branch,
        'auto_sync_on_push': autoSyncOnPush,
      },
      timeout: const Duration(minutes: 3),
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Polls an ARQ-queued GitHub App indexing job.
  Future<Map<String, dynamic>> pollGitHubAppJob(String jobId) async {
    final data = await apiClient.get('/v1/github-app/jobs/$jobId');
    return Map<String, dynamic>.from(data as Map);
  }

  /// Disconnects and purges a GitHub App repository's code graph.
  Future<void> disconnectGitHubAppRepo(String owner, String repo) async {
    await apiClient.delete('/v1/github-app/repos/$owner/$repo');
  }
}
