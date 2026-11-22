import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

class BackendStats {
  final int nodeCount;
  final int vectorCount;
  final int sourceCount;

  BackendStats({
    required this.nodeCount,
    required this.vectorCount,
    this.sourceCount = 0,
  });

  factory BackendStats.fromJson(Map<String, dynamic> json) {
    return BackendStats(
      nodeCount:
          ((json['node_count'] ?? json['nodeCount']) as num?)?.toInt() ?? 0,
      vectorCount:
          ((json['vector_count'] ?? json['vectorCount']) as num?)?.toInt() ?? 0,
      sourceCount:
          ((json['source_count'] ?? json['sourceCount']) as num?)?.toInt() ?? 0,
    );
  }
}

class IndexedSourceItem {
  final String id;
  final String name;
  final String subtitle;
  final String type;
  final String category; // 'repo' | 'doc' | 'feed'
  final String counts;
  final String lastSynced;
  final bool isStale;

  const IndexedSourceItem({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.type,
    required this.category,
    required this.counts,
    required this.lastSynced,
    this.isStale = false,
  });

  factory IndexedSourceItem.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? 'unknown';
    return IndexedSourceItem(
      id: json['id'] as String? ?? name,
      name: name,
      subtitle: json['subtitle'] as String? ?? '',
      type: json['type'] as String? ?? 'Document',
      category: json['category'] as String? ?? 'doc',
      counts: json['counts'] as String? ?? '',
      lastSynced: json['last_synced'] as String? ?? 'Indexed',
      isStale: json['is_stale'] as bool? ?? false,
    );
  }

  IndexedSourceItem copyWith({
    String? lastSynced,
    bool? isStale,
  }) {
    return IndexedSourceItem(
      id: id,
      name: name,
      subtitle: subtitle,
      type: type,
      category: category,
      counts: counts,
      lastSynced: lastSynced ?? this.lastSynced,
      isStale: isStale ?? this.isStale,
    );
  }
}

class IngestionJobItem {
  final String jobId;
  final String source;
  final String stage;
  final double progress;

  const IngestionJobItem({
    required this.jobId,
    required this.source,
    required this.stage,
    this.progress = 0.0,
  });

  factory IngestionJobItem.fromJson(Map<String, dynamic> json) {
    return IngestionJobItem(
      jobId: json['job_id'] as String? ?? '',
      source: json['source'] as String? ?? 'Document',
      stage: json['stage'] as String? ?? 'Processing',
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class SourcesSnapshot {
  final List<IndexedSourceItem> sources;
  final List<IngestionJobItem> queue;

  const SourcesSnapshot({
    this.sources = const [],
    this.queue = const [],
  });
}

final knowledgeHubRepositoryProvider = Provider<KnowledgeHubRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return KnowledgeHubRepository(apiClient: apiClient);
});

class KnowledgeHubRepository {
  final ApiClient apiClient;

  KnowledgeHubRepository({required this.apiClient});

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

  Future<SourcesSnapshot> fetchSources() async {
    final data = await apiClient.get('/admin/sources') as Map<String, dynamic>;
    final rawSources = data['sources'] as List<dynamic>? ?? const [];
    final rawQueue = data['queue'] as List<dynamic>? ?? const [];
    return SourcesSnapshot(
      sources: rawSources
          .map((e) => IndexedSourceItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      queue: rawQueue
          .map((e) => IngestionJobItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Future<Map<String, dynamic>> deleteSource({
    required String sourceId,
    required String category,
  }) async {
    final encodedId = Uri.encodeQueryComponent(sourceId);
    final encodedCategory = Uri.encodeQueryComponent(category);
    final data = await apiClient.delete(
      '/admin/sources?source_id=$encodedId&category=$encodedCategory',
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> reindexSource({
    required String sourceId,
    required String category,
  }) async {
    final data = await apiClient.post(
      '/admin/sources/reindex',
      body: {
        'source_id': sourceId,
        'category': category,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }
}
