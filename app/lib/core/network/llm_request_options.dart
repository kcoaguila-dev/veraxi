import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/models/model_provider_mapper.dart';

/// Resolves BYOD/local-LLM request options (`model`, `api_key`, `base_url`)
/// from [storage] for a selected [model] identifier.
Future<Map<String, String>> resolveLlmRequestOptions(
  ApiKeyStorage storage,
  String? model,
) async {
  final provider = ModelProviderMapper.resolve(model);
  final apiKey = await storage.getKey(provider);
  String? baseUrl;
  String? resolvedModel = model;

  if (provider == 'local') {
    final customBaseUrl = await storage.getValue('local_base_url');
    final customModelName = await storage.getValue('local_model_name');
    if (customBaseUrl != null && customBaseUrl.isNotEmpty) {
      baseUrl = customBaseUrl;
    }
    if (customModelName != null && customModelName.isNotEmpty) {
      resolvedModel = customModelName;
    }
  }

  return {
    if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey,
    if (baseUrl != null) 'base_url': baseUrl,
    if (resolvedModel != null &&
        resolvedModel.isNotEmpty &&
        resolvedModel != 'Select a model' &&
        resolvedModel != 'local-model')
      'model': resolvedModel,
  };
}
