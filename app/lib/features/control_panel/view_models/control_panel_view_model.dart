import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/control_panel_repository.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../../../core/network/api_client.dart';

class ControlPanelState {
  final bool isIngesting;
  final String? error;
  final String? successMessage;
  final BackendStats? stats;
  final Map<String, dynamic>? schema;
  final bool requiresPayment;

  const ControlPanelState({
    this.isIngesting = false,
    this.error,
    this.successMessage,
    this.stats,
    this.schema,
    this.requiresPayment = false,
  });
}

final controlPanelViewModelProvider =
    StateNotifierProvider<ControlPanelViewModel, ControlPanelState>((ref) {
  final repository = ref.watch(controlPanelRepositoryProvider);
  return ControlPanelViewModel(repository);
});

class ControlPanelViewModel extends StateNotifier<ControlPanelState> {
  final ControlPanelRepository repository;

  ControlPanelViewModel(this.repository) : super(const ControlPanelState()) {
    fetchStats();
    fetchSchema();
  }

  Future<void> fetchSchema() async {
    try {
      final schema = await repository.getSchema();
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: state.stats,
        schema: schema,
        error: null,
        successMessage: null,
        requiresPayment: state.requiresPayment,
      );
    } on PaymentRequiredException catch (_) {
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: state.stats,
        schema: state.schema,
        requiresPayment: true,
      );
    } catch (e) {
      // Ignore if no schema found or error, it will just remain null
    }
  }

  Future<void> saveSchema(Map<String, dynamic> newSchema) async {
    try {
      await repository.setSchema(newSchema);
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: state.stats,
        schema: newSchema,
        error: null,
        successMessage: 'Schema saved successfully.',
        requiresPayment: state.requiresPayment,
      );
    } on PaymentRequiredException catch (_) {
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: state.stats,
        schema: state.schema,
        requiresPayment: true,
      );
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: state.stats,
        schema: state.schema,
        error: e.toString(),
        successMessage: state.successMessage,
      );
    }
  }

  Future<void> autoGenerateSchema(String text) async {
    state = ControlPanelState(
      isIngesting: true, // Reuse for spinner
      stats: state.stats,
      schema: state.schema,
      error: null,
      successMessage: null,
        requiresPayment: state.requiresPayment,
      );
    try {
      final schema = await repository.autoGenerateSchema(text);
      await saveSchema(schema);
    } on PaymentRequiredException catch (_) {
      state = ControlPanelState(
        isIngesting: false,
        stats: state.stats,
        schema: state.schema,
        requiresPayment: true,
      );
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = ControlPanelState(
        isIngesting: false,
        stats: state.stats,
        schema: state.schema,
        error: e.toString(),
        successMessage: state.successMessage,
      );
    }
  }

  Future<void> fetchStats() async {
    try {
      final stats = await repository.fetchStats();
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: stats,
        schema: state.schema,
        error: null,
        successMessage: null,
        requiresPayment: state.requiresPayment,
      );
    } on PaymentRequiredException catch (_) {
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: state.stats,
        schema: state.schema,
        requiresPayment: true,
      );
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: state.stats,
        schema: state.schema,
        error: e.toString(),
        successMessage: state.successMessage,
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
          state = ControlPanelState(
            isIngesting: false,
            stats: state.stats,
            schema: state.schema,
            error: null,
            successMessage:
                'Ingestion complete: $nodes nodes and $vectors vectors inserted.',
        requiresPayment: state.requiresPayment,
      );
          await fetchStats();
          return;
        } else if (status == 'error' || status == 'not_found') {
          throw Exception(statusResult['error'] ?? 'Job failed');
        }
      }
    } else {
      await fetchStats();
      final nodes = result['nodes_inserted'] ?? 0;
      final vectors = result['vectors_inserted'] ?? 0;
      state = ControlPanelState(
        isIngesting: false,
        stats: state.stats,
        schema: state.schema,
        error: null,
        successMessage:
            'Ingestion complete: $nodes nodes and $vectors vectors inserted.',
        requiresPayment: state.requiresPayment,
      );
    }
  }

  Future<void> triggerIngestion(String text) async {
    state = ControlPanelState(
      isIngesting: true,
      stats: state.stats,
      schema: state.schema,
      error: null,
      successMessage: null,
        requiresPayment: state.requiresPayment,
      );

    try {
      final result = await repository.triggerIngestion(text);
      await _handleJobResult(result);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = ControlPanelState(
        isIngesting: false,
        stats: state.stats,
        schema: state.schema,
        error: e.toString(),
        successMessage: state.successMessage,
      );
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
    state = ControlPanelState(
      isIngesting: true,
      stats: state.stats,
      schema: state.schema,
      error: null,
      successMessage: null,
        requiresPayment: state.requiresPayment,
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
      state = ControlPanelState(
        isIngesting: false,
        stats: state.stats,
        schema: state.schema,
        error: e.toString(),
        successMessage: state.successMessage,
      );
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
    state = ControlPanelState(
      isIngesting: true,
      stats: state.stats,
      schema: state.schema,
      error: null,
      successMessage: null,
        requiresPayment: state.requiresPayment,
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
      state = ControlPanelState(
        isIngesting: false,
        stats: state.stats,
        schema: state.schema,
        error: e.toString(),
        successMessage: state.successMessage,
      );
      rethrow;
    }
  }
}
