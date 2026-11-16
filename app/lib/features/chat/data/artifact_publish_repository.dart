import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// A published artifact as the backend reports it: its id and the
/// public URL anyone can open.
class PublishedArtifact {
  final String id;
  final String url;

  const PublishedArtifact({required this.id, required this.url});
}

/// Talks to the backend's artifact publishing endpoints
/// (`POST /api/artifacts/publish`, `DELETE /api/artifacts/{id}`).
/// Publishing requires a signed-in session — the backend rejects
/// guest tenants with 401, which [ApiClient] surfaces as an
/// exception. The public page itself is served by the backend at
/// `/a/{id}`; this repository never fetches it.
class ArtifactPublishRepository {
  ArtifactPublishRepository(this._apiClient);

  final ApiClient _apiClient;

  /// Publishes [code] and returns its public identity. When
  /// [existingId] names an artifact the caller already published,
  /// the backend updates it in place and the URL stays the same.
  Future<PublishedArtifact> publish({
    required String title,
    String? fileName,
    required String language,
    required String code,
    required String kind,
    String? existingId,
  }) async {
    final response = await _apiClient.post('/artifacts/publish', body: {
      'title': title,
      'file_name': fileName,
      'language': language,
      'code': code,
      'kind': kind,
      if (existingId != null) 'id': existingId,
    });
    return PublishedArtifact(
      id: response['id'] as String,
      url: response['url'] as String,
    );
  }

  /// Removes a published artifact; its public URL stops working.
  Future<void> unpublish(String id) async {
    await _apiClient.delete('/artifacts/$id');
  }
}

final artifactPublishRepositoryProvider =
    Provider<ArtifactPublishRepository>((ref) {
  return ArtifactPublishRepository(ref.watch(apiClientProvider));
});
