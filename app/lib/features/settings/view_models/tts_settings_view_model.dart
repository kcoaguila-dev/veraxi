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
  final String selectedEngine;
  final String gptSovitsUrl;

  TTSSettingsState({
    this.isLoading = false,
    this.error,
    this.voices = const [],
    this.selectedVoiceId = 'default_system',
    this.selectedEngine = 'Browser',
    this.gptSovitsUrl = 'http://localhost:9880',
  });

  TTSSettingsState copyWith({
    bool? isLoading,
    String? error,
    bool clearError = false,
    List<Map<String, String>>? voices,
    String? selectedVoiceId,
    String? selectedEngine,
    String? gptSovitsUrl,
  }) {
    return TTSSettingsState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      voices: voices ?? this.voices,
      selectedVoiceId: selectedVoiceId ?? this.selectedVoiceId,
      selectedEngine: selectedEngine ?? this.selectedEngine,
      gptSovitsUrl: gptSovitsUrl ?? this.gptSovitsUrl,
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
      final savedEngine = await _storage.getEngine() ?? 'Browser';
      final savedUrl = await _storage.getGptSovitsUrl() ?? 'http://localhost:9880';
      final voices = await _repository.getVoices(gptSovitsUrl: savedUrl);
      state = state.copyWith(
        isLoading: false,
        voices: voices,
        selectedVoiceId: savedVoiceId,
        selectedEngine: savedEngine,
        gptSovitsUrl: savedUrl,
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      // Fallback to default if API fails
      final defaultVoices = [
        {'id': 'default_system', 'name': 'Default (System)'}
      ];
      final savedVoiceId = await _storage.getVoiceId() ?? 'default_system';
      final savedUrl = await _storage.getGptSovitsUrl() ?? 'http://localhost:9880';
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load voices: $e',
        voices: defaultVoices,
        selectedVoiceId: savedVoiceId,
        gptSovitsUrl: savedUrl,
      );
    }
  }

  Future<void> setVoice(String voiceId) async {
    await _storage.saveVoiceId(voiceId);
    state = state.copyWith(selectedVoiceId: voiceId);
  }

  Future<void> setEngine(String engine) async {
    await _storage.saveEngine(engine);
    state = state.copyWith(selectedEngine: engine);
  }

  Future<void> setGptSovitsUrl(String url) async {
    await _storage.saveGptSovitsUrl(url);
    state = state.copyWith(gptSovitsUrl: url);
    // Reload voices when URL changes
    _init();
  }
}
