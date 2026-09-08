import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/api_key_storage.dart';

final memoryRepositoryProvider = Provider<MemoryRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final apiKeyStorage = ref.watch(apiKeyStorageProvider);
  return MemoryRepository(apiClient: apiClient, apiKeyStorage: apiKeyStorage);
});

class MemoryRepository {
  final ApiClient apiClient;
  final ApiKeyStorage apiKeyStorage;

  MemoryRepository({required this.apiClient, required this.apiKeyStorage});

  String _getProviderFromModel(String? model) {
    if (model == null || model.isEmpty) return 'unknown';
    model = model.toLowerCase();
    if (model.startsWith('gemini')) return 'google';
    if (model.startsWith('gpt') ||
        model.startsWith('o1') ||
        model.startsWith('o3')) return 'openai';
    if (model.startsWith('claude')) return 'anthropic';
    if (model.startsWith('deepseek')) return 'deepseek';
    if (model.startsWith('moonshot')) return 'kimi';
    if (model.startsWith('llama') ||
        model.startsWith('qwen') ||
        model.startsWith('allam') ||
        model.startsWith('canopy') ||
        model.startsWith('groq') ||
        model.startsWith('meta')) return 'groq';
    if (model == 'local-model') return 'local';
    return 'unknown';
  }

  Future<void> saveToMemory(String content, {String? model}) async {
    final body = <String, dynamic>{'content': content};

    if (model != null && model.isNotEmpty && model != 'Select a model') {
      final provider = _getProviderFromModel(model);
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
