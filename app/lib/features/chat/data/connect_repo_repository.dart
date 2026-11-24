import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';

/// Provider for [ConnectRepoRepository].
final connectRepoRepositoryProvider = Provider<ConnectRepoRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return ConnectRepoRepository(apiClient: client);
});

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
}
