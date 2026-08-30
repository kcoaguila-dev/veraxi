import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

class BackendStats {
  final int nodeCount;
  final int vectorCount;

  BackendStats({required this.nodeCount, required this.vectorCount});

  factory BackendStats.fromJson(Map<String, dynamic> json) {
    return BackendStats(
      nodeCount: json['nodeCount'] ?? 0,
      vectorCount: json['vectorCount'] ?? 0,
    );
  }
}

final controlPanelRepositoryProvider = Provider<ControlPanelRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ControlPanelRepository(apiClient: apiClient);
});

class ControlPanelRepository {
  final ApiClient apiClient;

  ControlPanelRepository({required this.apiClient});

  Future<BackendStats> fetchStats() async {
    final data = await apiClient.get('/api/admin/stats');
    return BackendStats.fromJson(data);
  }

  Future<Map<String, dynamic>> triggerIngestion(String text,
      {bool fastExtraction = false,
      String language = 'en',
      String customStopWords = '',
      String model = 'gemini-2.5-flash-lite'}) async {
    final data = await apiClient.post('/api/admin/ingest', body: {
      'text': text,
      'fast_extraction': fastExtraction,
      'language': language,
      'model': model,
      'custom_stop_words': customStopWords
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
    });
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> ingestUrl(String url,
      {bool fastExtraction = false,
      String language = 'en',
      String customStopWords = '',
      String model = 'gemini-2.5-flash-lite'}) async {
    final data = await apiClient.post('/api/admin/ingest/url', body: {
      'url': url,
      'fast_extraction': fastExtraction,
      'language': language,
      'model': model,
      'custom_stop_words': customStopWords
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
    });
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> ingestUpload(
      List<int> fileBytes, String fileName,
      {bool fastExtraction = false,
      String language = 'en',
      String customStopWords = '',
      String model = 'gemini-2.5-flash-lite'}) async {
    final data = await apiClient.postMultipart(
      '/api/admin/ingest/upload',
      fileBytes: fileBytes,
      fileName: fileName,
      fields: {
        'fast_extraction': fastExtraction.toString(),
        'language': language,
        'model': model,
        'custom_stop_words': customStopWords,
      },
    );
    return data as Map<String, dynamic>;
  }
}
