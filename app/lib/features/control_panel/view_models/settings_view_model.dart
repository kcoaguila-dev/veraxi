import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/control_panel/data/settings_repository.dart';

final settingsRepositoryProvider = Provider((ref) => SettingsRepository());

class SettingsState {
  final String geminiKey;
  final BackendStats? stats;
  final bool isLoading;
  final String? error;

  SettingsState({
    this.geminiKey = '',
    this.stats,
    this.isLoading = false,
    this.error,
  });

  SettingsState copyWith({
    String? geminiKey,
    BackendStats? stats,
    bool? isLoading,
    String? error,
  }) {
    return SettingsState(
      geminiKey: geminiKey ?? this.geminiKey,
      stats: stats ?? this.stats,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class SettingsViewModel extends StateNotifier<SettingsState> {
  final SettingsRepository _repository;

  SettingsViewModel(this._repository) : super(SettingsState()) {
    _init();
  }

  Future<void> _init() async {
    state = state.copyWith(isLoading: true);
    try {
      final key = await _repository.getGeminiKey() ?? '';
      final stats = await _repository.fetchStats();
      state = state.copyWith(
          geminiKey: key, stats: stats, isLoading: false, error: null);
    } catch (e) {
      // If backend is down, we still load the key
      final key = await _repository.getGeminiKey() ?? '';
      state =
          state.copyWith(geminiKey: key, isLoading: false, error: e.toString());
    }
  }

  Future<void> refreshStats() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final stats = await _repository.fetchStats();
      state = state.copyWith(stats: stats, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> saveGeminiKey(String key) async {
    await _repository.saveGeminiKey(key);
    state = state.copyWith(geminiKey: key);
  }
}

final settingsViewModelProvider =
    StateNotifierProvider<SettingsViewModel, SettingsState>((ref) {
  return SettingsViewModel(ref.read(settingsRepositoryProvider));
});
