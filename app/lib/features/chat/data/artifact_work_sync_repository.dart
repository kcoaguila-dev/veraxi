import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/artifact_work_store.dart';

/// Syncs artifact panel work with the backend, where it is stored
/// per tenant next to the chat history it belongs to (Redis), so
/// work follows the user across devices the way threads do:
/// `PUT /api/artifacts/work/{threadId}` saves one artifact's
/// state, `GET` returns every saved state for the thread.
class ArtifactWorkSyncRepository {
  ArtifactWorkSyncRepository(this._apiClient);

  final ApiClient _apiClient;

  /// Every saved work state for a thread, keyed by
  /// `"<messageIndex>:<artifactIndex>"`.
  Future<Map<String, ArtifactWorkState>> fetchThreadWork(
    String threadId,
  ) async {
    final data = await _apiClient.get('/artifacts/work/$threadId');
    final entries =
        (data as Map<String, dynamic>)['entries'] as Map<String, dynamic>? ??
            const {};
    return entries.map(
      (key, value) => MapEntry(
        key,
        ArtifactWorkState.fromJson(
          (value as Map<dynamic, dynamic>).cast<String, dynamic>(),
        ),
      ),
    );
  }

  /// Saves one artifact's work state server-side.
  Future<void> saveWork({
    required String threadId,
    required int messageIndex,
    required int artifactIndex,
    required ArtifactWorkState state,
  }) async {
    await _apiClient.put('/artifacts/work/$threadId', body: {
      'message_index': messageIndex,
      'artifact_index': artifactIndex,
      'state': state.toJson(),
    });
  }
}

final artifactWorkSyncRepositoryProvider =
    Provider<ArtifactWorkSyncRepository>((ref) {
  return ArtifactWorkSyncRepository(ref.watch(apiClientProvider));
});
