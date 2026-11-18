import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/knowledge_hub/data/corpus_insights_repository.dart';

// Re-export the models so views can import them from the ViewModel
// layer without violating the views → view_models → data contract.
export 'package:veraxi_app/features/knowledge_hub/data/corpus_insights_repository.dart'
    show
        BriefingCommunity,
        BriefingEntity,
        ContradictionFlag,
        CorpusBriefing,
        DbtDatasetMatch,
        NewestEntity;

/// State for the Corpus Briefing & dbt Lineage panel.
class CorpusInsightsState {
  final CorpusBriefing? briefing;
  final bool loadingBriefing;
  final String? briefingError;
  final bool ingestingManifest;
  final String? manifestStatus;
  final String? manifestError;
  final List<DbtDatasetMatch> datasetMatches;
  final bool searchingDatasets;
  final String? datasetError;

  const CorpusInsightsState({
    this.briefing,
    this.loadingBriefing = false,
    this.briefingError,
    this.ingestingManifest = false,
    this.manifestStatus,
    this.manifestError,
    this.datasetMatches = const [],
    this.searchingDatasets = false,
    this.datasetError,
  });

  CorpusInsightsState copyWith({
    CorpusBriefing? briefing,
    bool? loadingBriefing,
    String? briefingError,
    bool clearBriefingError = false,
    bool? ingestingManifest,
    String? manifestStatus,
    bool clearManifestStatus = false,
    String? manifestError,
    bool clearManifestError = false,
    List<DbtDatasetMatch>? datasetMatches,
    bool? searchingDatasets,
    String? datasetError,
    bool clearDatasetError = false,
  }) {
    return CorpusInsightsState(
      briefing: briefing ?? this.briefing,
      loadingBriefing: loadingBriefing ?? this.loadingBriefing,
      briefingError:
          clearBriefingError ? null : (briefingError ?? this.briefingError),
      ingestingManifest: ingestingManifest ?? this.ingestingManifest,
      manifestStatus:
          clearManifestStatus ? null : (manifestStatus ?? this.manifestStatus),
      manifestError:
          clearManifestError ? null : (manifestError ?? this.manifestError),
      datasetMatches: datasetMatches ?? this.datasetMatches,
      searchingDatasets: searchingDatasets ?? this.searchingDatasets,
      datasetError:
          clearDatasetError ? null : (datasetError ?? this.datasetError),
    );
  }
}

final corpusInsightsViewModelProvider =
    StateNotifierProvider<CorpusInsightsViewModel, CorpusInsightsState>((ref) {
  final repository = ref.watch(corpusInsightsRepositoryProvider);
  return CorpusInsightsViewModel(repository);
});

class CorpusInsightsViewModel extends StateNotifier<CorpusInsightsState> {
  final CorpusInsightsRepository _repository;

  CorpusInsightsViewModel(this._repository)
      : super(const CorpusInsightsState());

  Future<void> loadBriefing() async {
    state = state.copyWith(loadingBriefing: true, clearBriefingError: true);
    try {
      final briefing = await _repository.fetchBriefing();
      state = state.copyWith(briefing: briefing, loadingBriefing: false);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        loadingBriefing: false,
        briefingError: 'Failed to load corpus briefing',
      );
    }
  }

  /// Ingest manifest.json file bytes picked by the view (file_picker).
  Future<void> ingestManifestBytes(List<int> bytes) async {
    state = state.copyWith(
      ingestingManifest: true,
      clearManifestError: true,
      clearManifestStatus: true,
    );
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        state = state.copyWith(
          ingestingManifest: false,
          manifestError: 'manifest.json must contain a JSON object',
        );
        return;
      }
      final result = await _repository.ingestDbtManifest(
        Map<String, dynamic>.from(decoded),
      );
      state = state.copyWith(
        ingestingManifest: false,
        manifestStatus:
            'Ingested ${result['nodes_written'] ?? 0} nodes, ${result['edges_written'] ?? 0} edges',
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        ingestingManifest: false,
        manifestError: 'Failed to ingest manifest.json',
      );
    }
  }

  Future<void> searchDatasets(String query) async {
    state = state.copyWith(searchingDatasets: true, clearDatasetError: true);
    try {
      final matches = await _repository.searchDatasets(query.trim());
      state = state.copyWith(datasetMatches: matches, searchingDatasets: false);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        searchingDatasets: false,
        datasetError: 'Dataset search failed',
      );
    }
  }
}
