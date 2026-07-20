import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/control_panel_repository.dart';

class ControlPanelState {
  final bool isIngesting;
  final String? error;
  final String? successMessage;
  final BackendStats? stats;

  const ControlPanelState({
    this.isIngesting = false,
    this.error,
    this.successMessage,
    this.stats,
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
  }

  Future<void> fetchStats() async {
    try {
      final stats = await repository.fetchStats();
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: stats,
        error: null,
        successMessage: null,
      );
    } catch (e) {
      state = ControlPanelState(
        isIngesting: state.isIngesting,
        stats: state.stats,
        error: e.toString(),
        successMessage: state.successMessage,
      );
    }
  }

  Future<void> triggerIngestion(String text) async {
    state = ControlPanelState(
      isIngesting: true,
      stats: state.stats,
      error: null,
      successMessage: null,
    );

    try {
      final result = await repository.triggerIngestion(text);

      await fetchStats();

      final nodes = result['nodes_inserted'] ?? 0;
      final vectors = result['vectors_inserted'] ?? 0;

      state = ControlPanelState(
        isIngesting: false,
        stats: state.stats,
        error: null,
        successMessage: 'Ingestion complete: ${nodes} nodes and ${vectors} vectors inserted.',
      );
    } catch (e) {
      state = ControlPanelState(
        isIngesting: false,
        stats: state.stats,
        error: e.toString(),
        successMessage: state.successMessage,
      );
    }
  }
}
