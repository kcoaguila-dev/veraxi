import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/settings/data/memory_repository.dart';

// Re-export the model so views can import it from the ViewModel layer
// without violating the views → view_models → data dependency contract.
export 'package:veraxi_app/features/settings/data/memory_repository.dart'
    show UserMemory;

/// State for the Memory settings tab.
class MemoryState {
  final List<UserMemory> memories;
  final bool loading;
  final String? error;

  const MemoryState({
    this.memories = const [],
    this.loading = true,
    this.error,
  });

  MemoryState copyWith({
    List<UserMemory>? memories,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return MemoryState(
      memories: memories ?? this.memories,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final memoryViewModelProvider =
    StateNotifierProvider<MemoryViewModel, MemoryState>((ref) {
  final repository = ref.watch(memoryRepositoryProvider);
  return MemoryViewModel(repository);
});

class MemoryViewModel extends StateNotifier<MemoryState> {
  final MemoryRepository _repository;

  MemoryViewModel(this._repository) : super(const MemoryState()) {
    load();
  }

  Future<void> load() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final memories = await _repository.getMemories();
      state = state.copyWith(memories: memories, loading: false);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        loading: false,
        error: 'Failed to load memories',
      );
    }
  }

  Future<void> addMemory(String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    try {
      final created = await _repository.createMemory(trimmed);
      state = state.copyWith(memories: [created, ...state.memories]);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to add memory');
    }
  }

  Future<void> editMemory(String id, String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    try {
      final updated = await _repository.updateMemory(id, trimmed);
      state = state.copyWith(
        memories: [
          for (final memory in state.memories)
            if (memory.id == id) updated else memory,
        ],
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to update memory');
    }
  }

  Future<void> expireMemory(String id) async {
    try {
      final updated = await _repository.expireMemory(id);
      state = state.copyWith(
        memories: [
          for (final memory in state.memories)
            if (memory.id == id) updated else memory,
        ],
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to expire memory');
    }
  }

  Future<void> deleteMemory(String id) async {
    try {
      await _repository.deleteMemory(id);
      state = state.copyWith(
        memories: state.memories.where((m) => m.id != id).toList(),
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to delete memory');
    }
  }
}
