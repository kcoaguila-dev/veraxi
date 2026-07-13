import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/control_panel_repository.dart';

class ControlPanelState {
  final int nodeCount;
  final int vectorCount;
  final bool isIngesting;
  final String? error;
  final String? successMessage;

  const ControlPanelState({
    this.nodeCount = 0,
    this.vectorCount = 0,
    this.isIngesting = false,
    this.error,
    this.successMessage,
  });

  ControlPanelState copyWith({
    int? nodeCount,
    int? vectorCount,
    bool? isIngesting,
    String? error,
    String? successMessage,
    bool clearError = false,
    bool clearSuccessMessage = false,
  }) {
    return ControlPanelState(
      nodeCount: nodeCount ?? this.nodeCount,
      vectorCount: vectorCount ?? this.vectorCount,
      isIngesting: isIngesting ?? this.isIngesting,
      error: clearError ? null : (error ?? this.error),
      successMessage: clearSuccessMessage ? null : (successMessage ?? this.successMessage),
    );
  }
}

final controlPanelRepositoryProvider = Provider<ControlPanelRepository>((ref) {
  return ControlPanelRepository();
});

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
      state = state.copyWith(
        nodeCount: stats['node_count'] as int? ?? 0,
        vectorCount: stats['vector_count'] as int? ?? 0,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> triggerIngestion() async {
    state = state.copyWith(
      isIngesting: true,
      clearError: true,
      clearSuccessMessage: true,
    );

    try {
      final result = await repository.triggerIngestion();

      // Update counts based on the returned result, or we can just fetchStats again
      await fetchStats();

      final nodes = result['nodes_inserted'] ?? 0;
      final vectors = result['vectors_inserted'] ?? 0;

      state = state.copyWith(
        isIngesting: false,
        successMessage: 'Ingestion complete: ${nodes} nodes and ${vectors} vectors inserted.',
      );
    } catch (e) {
      state = state.copyWith(
        isIngesting: false,
        error: e.toString(),
      );
    }
  }
}
