import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/chat/data/deep_cost_repository.dart';

// Re-export the model so views can import it from the ViewModel layer
// without violating the views → view_models → data dependency contract.
export 'package:veraxi_app/features/chat/data/deep_cost_repository.dart'
    show DeepCostEstimate, DeepCostRange;

/// Debounced Deep-mode pre-flight estimate for a given model.
///
/// Keyed by model because the backend estimate depends only on the
/// model (and the debate constants) — never on the query text.
/// State is null while debouncing/loading and stays null when the
/// fetch fails (offline, unknown backend), so the view renders no
/// chip rather than a wrong or invented figure.
final deepCostEstimateProvider = StateNotifierProvider.autoDispose
    .family<DeepCostViewModel, DeepCostEstimate?, String?>((ref, model) {
  final repository = ref.watch(deepCostRepositoryProvider);
  return DeepCostViewModel(repository, model);
});

class DeepCostViewModel extends StateNotifier<DeepCostEstimate?> {
  final DeepCostRepository _repository;
  final String? _model;
  Timer? _debounce;
  bool _disposed = false;

  DeepCostViewModel(this._repository, this._model) : super(null) {
    _debounce = Timer(const Duration(milliseconds: 300), _fetch);
  }

  Future<void> _fetch() async {
    final model = _model;
    if (model == null || model.isEmpty || model == 'Select a model') return;
    try {
      final estimate = await _repository.estimateDeepCost(model: model);
      if (!_disposed) state = estimate;
    } catch (e, st) {
      // Graceful failure: no chip is better than a wrong figure.
      await Sentry.captureException(e, stackTrace: st);
      if (!_disposed) state = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    super.dispose();
  }
}
