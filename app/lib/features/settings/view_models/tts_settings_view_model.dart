import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/core/tts_settings_storage.dart';

final ttsSettingsViewModelProvider =
    StateNotifierProvider<TTSSettingsViewModel, TTSSettingsState>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final repository = ChatRepository(apiClient: apiClient);
  return TTSSettingsViewModel(repository);
});

class TTSSettingsState {
  final bool isLoading;
  final String? error;
  final List<Map<String, String>> voices;
  final String selectedVoiceId;

  TTSSettingsState({
    this.isLoading = false,
    this.error,
    this.voices = const [],
    this.selectedVoiceId = 'default_system',
  });

  TTSSettingsState copyWith({
    bool? isLoading,
    String? error,
    bool clearError = false,
    List<Map<String, String>>? voices,
    String? selectedVoiceId,
  }) {
    return TTSSettingsState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      voices: voices ?? this.voices,
      selectedVoiceId: selectedVoiceId ?? this.selectedVoiceId,
    );
  }
}

class TTSSettingsViewModel extends StateNotifier<TTSSettingsState> {
  final ChatRepository _repository;
  final TTSSettingsStorage _storage = TTSSettingsStorage();

  TTSSettingsViewModel(this._repository) : super(TTSSettingsState()) {
    _init();
  }

  Future<void> _init() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final savedVoiceId = await _storage.getVoiceId() ?? 'default_system';
      final voices = await _repository.getVoices();
      state = state.copyWith(
        isLoading: false,
        voices: voices,
        selectedVoiceId: savedVoiceId,
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      // Fallback to default if API fails
      final defaultVoices = [
        {'id': 'default_system', 'name': 'Default (System)'}
      ];
      final savedVoiceId = await _storage.getVoiceId() ?? 'default_system';
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load voices: $e',
        voices: defaultVoices,
        selectedVoiceId: savedVoiceId,
      );
    }
  }

  Future<void> setVoice(String voiceId) async {
    state = state.copyWith(selectedVoiceId: voiceId);
    await _storage.saveVoiceId(voiceId);
  }
}
