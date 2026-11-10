import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/models/model_provider_mapper.dart';

final memoryRepositoryProvider = Provider<MemoryRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final apiKeyStorage = ref.watch(apiKeyStorageProvider);
  return MemoryRepository(apiClient: apiClient, apiKeyStorage: apiKeyStorage);
});

class MemoryRepository {
  final ApiClient apiClient;
  final ApiKeyStorage apiKeyStorage;

  MemoryRepository({required this.apiClient, required this.apiKeyStorage});

  Future<void> saveToMemory(String content, {String? model}) async {
    final body = <String, dynamic>{'content': content};

    if (model != null && model.isNotEmpty && model != 'Select a model') {
      final provider = ModelProviderMapper.resolve(model);
      final apiKey = await apiKeyStorage.getKey(provider);

      body['model'] = model;
      if (apiKey != null && apiKey.isNotEmpty) {
        body['api_key'] = apiKey;
      }

      if (provider == 'local') {
        final customBaseUrl = await apiKeyStorage.getValue('local_base_url');
        if (customBaseUrl != null && customBaseUrl.isNotEmpty) {
          body['base_url'] = customBaseUrl;
        }
      }
    }

    await apiClient.post('/memory/ingest', body: body);
  }
}
