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
    try {
      final data = await apiClient.get(url);
      Map<String, List<String>> result = {};
      data.forEach((key, value) {
        result[key] = List<String>.from(value);
      });
      return result;
    } catch (e) {
      debugPrint('[ModelConfigRepository] getProviderModels error: $e');
      return {};
    }
  }
}
