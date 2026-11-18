import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/knowledge_hub/data/evals_repository.dart';

// Re-export the models so views can import them from the ViewModel
// layer without violating the views → view_models → data contract.
export 'package:veraxi_app/features/knowledge_hub/data/evals_repository.dart'
    show AblationReport, EvalConfigResults, EvalGroupMetrics;

/// State for the Evidence Evals section in Observability.
class EvalsState {
  final bool running;
  final AblationReport? report;
  final String? error;

  const EvalsState({this.running = false, this.report, this.error});

  EvalsState copyWith({
    bool? running,
    AblationReport? report,
    String? error,
    bool clearError = false,
  }) {
    return EvalsState(
      running: running ?? this.running,
      report: report ?? this.report,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final evalsViewModelProvider =
    StateNotifierProvider<EvalsViewModel, EvalsState>((ref) {
  final repository = ref.watch(evalsRepositoryProvider);
  return EvalsViewModel(repository);
});

class EvalsViewModel extends StateNotifier<EvalsState> {
  final EvalsRepository _repository;

  EvalsViewModel(this._repository) : super(const EvalsState());

  /// Parse the two JSON fields and run the ablation.
  ///
  /// There is no saved-benchmark store in the backend, so dataset
  /// and rankings are supplied with every run — invalid JSON is a
  /// local, immediate error and never reaches the network.
  Future<void> run(
      {required String datasetJson, required String rankingsJson}) async {
    Object dataset;
    Map<String, dynamic> rankings;
    try {
      final decodedDataset = jsonDecode(datasetJson);
      if (decodedDataset is! Map && decodedDataset is! List) {
        state = state.copyWith(
          error:
              'Dataset JSON must be an object with "cases" or a list of cases',
        );
        return;
      }
      dataset = decodedDataset;
      final decodedRankings = jsonDecode(rankingsJson);
      if (decodedRankings is! Map) {
        state = state.copyWith(
          error: 'Rankings JSON must be an object keyed by config name',
        );
        return;
      }
      rankings = Map<String, dynamic>.from(decodedRankings);
    } on FormatException catch (e) {
      state = state.copyWith(error: 'Invalid JSON: ${e.message}');
      return;
    }

    state = state.copyWith(running: true, clearError: true);
    try {
      final report = await _repository.runAblation(
        dataset: dataset,
        rankings: rankings,
      );
      state = state.copyWith(running: false, report: report);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        running: false,
        error: 'Ablation failed — check the dataset and rankings shape',
      );
    }
  }
}
