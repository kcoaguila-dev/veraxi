import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/models/model_provider_mapper.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// Talks to the backend's in-artifact AI endpoint
/// (`POST /api/artifacts/complete`), which runs one non-streaming
/// completion for `window.veraxi.complete` in artifact previews.
///
/// BYOK works exactly like chat: the key for the model's provider
/// is read from the app's secure storage here in the host app and
/// sent in the request body — it never enters the artifact frame,
/// which only ever sees the prompt it wrote and the text reply.
/// Throws on any non-200 response (see [ApiClient.post]).
class ArtifactAiRepository {
  ArtifactAiRepository(this._apiClient, this._apiKeyStorage);

  final ApiClient _apiClient;
  final ApiKeyStorage _apiKeyStorage;

  /// Runs a single completion and returns its text. [model] is the
  /// effective model id (the bridge resolves the selected chat
  /// model before calling); when it is null the backend falls back
  /// to its configured default model.
  Future<String> complete({
    required String prompt,
    String? system,
    String? model,
    int? maxTokens,
  }) async {
    var effectiveModel = model;
    String? apiKey;
    String? baseUrl;
    if (effectiveModel != null) {
      final provider = ModelProviderMapper.resolve(effectiveModel);
      apiKey = await _apiKeyStorage.getKey(provider);
      if (provider == 'local') {
        final customBaseUrl = await _apiKeyStorage.getValue('local_base_url');
        final customModelName =
            await _apiKeyStorage.getValue('local_model_name');
        if (customBaseUrl != null && customBaseUrl.isNotEmpty) {
          baseUrl = customBaseUrl;
        }
        if (customModelName != null && customModelName.isNotEmpty) {
          effectiveModel = customModelName;
        }
      }
    }
    final response = await _apiClient.post(
      '/artifacts/complete',
      // A completion can legitimately take longer than the default
      // 30s API timeout; the in-frame shim gives up at 60s.
      timeout: const Duration(seconds: 70),
      body: {
        'prompt': prompt,
        if (system != null) 'system': system,
        if (effectiveModel != null) 'model': effectiveModel,
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey,
        if (baseUrl != null) 'base_url': baseUrl,
      },
    );
    final text = response is Map ? response['text'] : null;
    if (text is! String) {
      throw Exception('AI completion returned no text');
    }
    return text;
  }
}

final artifactAiRepositoryProvider = Provider<ArtifactAiRepository>((ref) {
  return ArtifactAiRepository(
    ref.watch(apiClientProvider),
    ref.watch(apiKeyStorageProvider),
  );
});
