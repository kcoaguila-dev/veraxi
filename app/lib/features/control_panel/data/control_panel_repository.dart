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
    final data = await apiClient.get('/admin/stats');
    return BackendStats.fromJson(data);
  }

  Future<Map<String, dynamic>> triggerIngestion(String text,
      {bool fastExtraction = false,
      String language = 'en',
      String customStopWords = '',
      String model = 'gemini-2.5-flash-lite'}) async {
    final data = await apiClient.post('/admin/ingest', body: {
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
    final data = await apiClient.post('/admin/ingest/url', body: {
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
      '/admin/ingest/upload',
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

  Future<Map<String, dynamic>> getIngestStatus(String jobId) async {
    final data = await apiClient.get('/admin/ingest/status/$jobId');
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> getSchema() async {
    try {
      final data = await apiClient.get('/admin/schema');
      return data as Map<String, dynamic>;
    } catch (e) {
      if (e.toString().contains('404')) return null;
      rethrow;
    }
  }

  Future<void> setSchema(Map<String, dynamic> schema) async {
    await apiClient.post('/admin/schema', body: schema);
  }

  Future<Map<String, dynamic>> autoGenerateSchema(String text) async {
    final data = await apiClient.post('/admin/schema/auto-generate', body: {
      'text': text,
    });
    return data as Map<String, dynamic>;
  }
}
