import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../../../core/network/api_client.dart';
import '../data/knowledge_hub_repository.dart';

export '../data/knowledge_hub_repository.dart'
    show BackendStats, IndexedSourceItem, IngestionJobItem, SourcesSnapshot;

const List<IndexedSourceItem> defaultFallbackSources = [
  IndexedSourceItem(
    id: 'veraxi/backend',
    name: 'veraxi/backend',
    subtitle: 'backend',
    type: 'Code AST',
    category: 'repo',
    counts: '142 files · 812 nodes',
    lastSynced: '12m ago',
    isStale: false,
  ),
  IndexedSourceItem(
    id: 'architecture_v2_draft.pdf',
    name: 'architecture_v2_draft.pdf',
    subtitle: 'Uploaded · 4.2 MB',
    type: 'PDF',
    category: 'doc',
    counts: '64 chunks · 91 nodes',
    lastSynced: '18d ago',
    isStale: true,
  ),
  IndexedSourceItem(
    id: 'nvd_kev_catalog',
    name: 'NVD + CISA KEV Catalog',
    subtitle: 'Public Vulnerability Feed',
    type: 'Vuln Graph',
    category: 'feed',
    counts: '1,140 CVE · KEV',
    lastSynced: '1h ago',
    isStale: false,
  ),
];

class KnowledgeHubState {
  final bool isIngesting;
  final String? error;
  final String? successMessage;
  final BackendStats? stats;
  final Map<String, dynamic>? schema;
  final bool requiresPayment;
  final List<IndexedSourceItem> sources;
  final List<IngestionJobItem> queue;
  final String? busySourceId;

  const KnowledgeHubState({
    this.isIngesting = false,
    this.error,
    this.successMessage,
    this.stats,
    this.schema,
    this.requiresPayment = false,
    this.sources = defaultFallbackSources,
    this.queue = const [],
    this.busySourceId,
  });

  KnowledgeHubState copyWith({
    bool? isIngesting,
    String? error,
    bool clearError = false,
    String? successMessage,
    bool clearSuccess = false,
    BackendStats? stats,
    Map<String, dynamic>? schema,
    bool? requiresPayment,
    List<IndexedSourceItem>? sources,
    List<IngestionJobItem>? queue,
    String? busySourceId,
    bool clearBusySource = false,
  }) {
    return KnowledgeHubState(
      isIngesting: isIngesting ?? this.isIngesting,
      error: clearError ? null : (error ?? this.error),
      successMessage:
          clearSuccess ? null : (successMessage ?? this.successMessage),
      stats: stats ?? this.stats,
      schema: schema ?? this.schema,
      requiresPayment: requiresPayment ?? this.requiresPayment,
      sources: sources ?? this.sources,
      queue: queue ?? this.queue,
      busySourceId:
          clearBusySource ? null : (busySourceId ?? this.busySourceId),
    );
  }
}

final knowledgeHubViewModelProvider =
    StateNotifierProvider<KnowledgeHubViewModel, KnowledgeHubState>((ref) {
  final repository = ref.watch(knowledgeHubRepositoryProvider);
  return KnowledgeHubViewModel(repository);
});

class KnowledgeHubViewModel extends StateNotifier<KnowledgeHubState> {
  final KnowledgeHubRepository repository;

  KnowledgeHubViewModel(this.repository) : super(const KnowledgeHubState()) {
    fetchStats();
    fetchSchema();
    fetchSources();
  }

  Future<void> fetchSchema() async {
    try {
      final schema = await repository.getSchema();
      state = state.copyWith(
        schema: schema,
        clearError: true,
        clearSuccess: true,
      );
    } on PaymentRequiredException catch (_) {
      state = state.copyWith(requiresPayment: true);
    } catch (_) {
      // Ignore if no schema found yet; user can define or auto-generate one.
    }
  }

  Future<void> fetchSources() async {
    try {
      final snapshot = await repository.fetchSources();
      state = state.copyWith(
        sources: snapshot.sources,
        queue: snapshot.queue,
      );
    } on PaymentRequiredException catch (_) {
      state = state.copyWith(requiresPayment: true);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
    }
  }

  Future<void> saveSchema(Map<String, dynamic> newSchema) async {
    try {
      await repository.setSchema(newSchema);
      state = state.copyWith(
        schema: newSchema,
        clearError: true,
        successMessage: 'Schema saved successfully.',
      );
    } on PaymentRequiredException catch (_) {
      state = state.copyWith(requiresPayment: true);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> autoGenerateSchema(String text) async {
    state = state.copyWith(
      isIngesting: true,
      clearError: true,
      clearSuccess: true,
    );
    try {
      final schema = await repository.autoGenerateSchema(text);
      await saveSchema(schema);
      state = state.copyWith(isIngesting: false);
    } on PaymentRequiredException catch (_) {
      state = state.copyWith(isIngesting: false, requiresPayment: true);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(isIngesting: false, error: e.toString());
    }
  }

  Future<void> fetchStats() async {
    try {
      final stats = await repository.fetchStats();
      state = state.copyWith(
        stats: stats,
        clearError: true,
        clearSuccess: true,
      );
    } on PaymentRequiredException catch (_) {
      state = state.copyWith(requiresPayment: true);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> deleteSource(IndexedSourceItem item) async {
    state = state.copyWith(
      busySourceId: item.id,
      clearError: true,
      clearSuccess: true,
    );
    try {
      await repository.deleteSource(
        sourceId: item.id,
        category: item.category,
      );
      final updated =
          state.sources.where((s) => s.id != item.id).toList(growable: false);
      state = state.copyWith(
        sources: updated,
        clearBusySource: true,
        successMessage: 'Deleted ${item.name} from graph and vector store.',
      );
      await fetchStats();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        clearBusySource: true,
        error: 'Failed to delete ${item.name}: $e',
      );
    }
  }

  Future<void> reindexSource(IndexedSourceItem item) async {
    state = state.copyWith(
      busySourceId: item.id,
      clearError: true,
      clearSuccess: true,
    );
    try {
      await repository.reindexSource(
        sourceId: item.id,
        category: item.category,
      );
      final updated = state.sources
          .map((s) => s.id == item.id
              ? s.copyWith(lastSynced: 'Just now', isStale: false)
              : s)
          .toList(growable: false);
      state = state.copyWith(
        sources: updated,
        clearBusySource: true,
        successMessage: 'Re-indexed ${item.name}.',
      );
      await fetchStats();
      await fetchSources();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        clearBusySource: true,
        error: 'Failed to re-index ${item.name}: $e',
      );
    }
  }

  Future<void> _handleJobResult(Map<String, dynamic> result) async {
    String? jobId = result['job_id'];
    if (jobId != null) {
      while (true) {
        await Future.delayed(const Duration(seconds: 3));
        final statusResult = await repository.getIngestStatus(jobId);
        final status = statusResult['status'];
        if (status == 'complete') {
          final res = statusResult['result'] ?? {};
          final nodes = res['nodes_inserted'] ?? 0;
          final vectors = res['vectors_inserted'] ?? 0;
          state = state.copyWith(
            isIngesting: false,
            clearError: true,
            successMessage:
                'Ingestion complete: $nodes nodes and $vectors vectors inserted.',
          );
          await fetchStats();
          await fetchSources();
          return;
        } else if (status == 'error' || status == 'not_found') {
          throw Exception(statusResult['error'] ?? 'Job failed');
        }
      }
    } else {
      await fetchStats();
      await fetchSources();
      final nodes = result['nodes_inserted'] ?? 0;
      final vectors = result['vectors_inserted'] ?? 0;
      state = state.copyWith(
        isIngesting: false,
        clearError: true,
        successMessage:
            'Ingestion complete: $nodes nodes and $vectors vectors inserted.',
      );
    }
  }

  Future<void> triggerIngestion(String text) async {
    state = state.copyWith(
      isIngesting: true,
      clearError: true,
      clearSuccess: true,
    );

    try {
      final result = await repository.triggerIngestion(text);
      await _handleJobResult(result);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(isIngesting: false, error: e.toString());
    }
  }

  Future<void> ingestUpload(
    List<int> fileBytes,
    String fileName, {
    bool fastExtraction = false,
    String language = 'en',
    String customStopWords = '',
    String model = 'gemini-2.5-flash-lite',
  }) async {
    state = state.copyWith(
      isIngesting: true,
      clearError: true,
      clearSuccess: true,
    );

    try {
      final result = await repository.ingestUpload(
        fileBytes,
        fileName,
        fastExtraction: fastExtraction,
        language: language,
        customStopWords: customStopWords,
        model: model,
      );
      await _handleJobResult(result);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(isIngesting: false, error: e.toString());
      rethrow;
    }
  }

  Future<void> ingestUrl(
    String url, {
    bool fastExtraction = false,
    String language = 'en',
    String customStopWords = '',
    String model = 'gemini-2.5-flash-lite',
  }) async {
    state = state.copyWith(
      isIngesting: true,
      clearError: true,
      clearSuccess: true,
    );

    try {
      final result = await repository.ingestUrl(
        url,
        fastExtraction: fastExtraction,
        language: language,
        customStopWords: customStopWords,
        model: model,
      );
      await _handleJobResult(result);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(isIngesting: false, error: e.toString());
      rethrow;
    }
  }
}
