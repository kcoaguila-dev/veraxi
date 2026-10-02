import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

final modelConfigRepositoryProvider = Provider<ModelConfigRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ModelConfigRepository(apiClient: apiClient);
});

/// Repository for model discovery and UI configuration endpoints.
class ModelConfigRepository {
  final ApiClient apiClient;

  ModelConfigRepository({required this.apiClient});

  Future<Map<String, dynamic>> getUIConfig() async {
    final url =
        '/config/ui?_=' + DateTime.now().millisecondsSinceEpoch.toString();
    try {
      final data = await apiClient.get(url);
      return data;
    } catch (e) {
      debugPrint('[ModelConfigRepository] getUIConfig error: $e');
      return {};
    }
  }

  Future<Map<String, List<String>>> getProviderModels() async {
    final url = '/models?_=' + DateTime.now().millisecondsSinceEpoch.toString();
    final data = await apiClient.get(url);
    if (data is! Map) {
      throw Exception('Expected Map but got ${data.runtimeType}');
    }

    Map<String, List<String>> result = {};
    for (var entry in data.entries) {
      result[entry.key.toString()] = List<String>.from(entry.value as Iterable);
    }
    return result;
  }
}
