import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/core/tts_settings_storage.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';

class AudioPlayerState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final String? playingMessageId;
  final String? playingText;
  final double speed;
  final bool isLoading;
  final String? errorMessage;

  AudioPlayerState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playingMessageId,
    this.playingText,
    this.speed = 1.0,
    this.isLoading = false,
    this.errorMessage,
  });

  AudioPlayerState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    String? playingMessageId,
    String? playingText,
    double? speed,
    bool? isLoading,
    String? errorMessage,
  }) {
    return AudioPlayerState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playingMessageId: playingMessageId ?? this.playingMessageId,
      playingText: playingText ?? this.playingText,
      speed: speed ?? this.speed,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  AudioPlayerState clearError() {
    return AudioPlayerState(
      isPlaying: isPlaying,
      position: position,
      duration: duration,
      playingMessageId: playingMessageId,
      playingText: playingText,
      speed: speed,
      isLoading: isLoading,
      errorMessage: null,
    );
  }
}

class AudioPlayerService extends StateNotifier<AudioPlayerState> {
  final AudioPlayer _player = AudioPlayer();
  final TTSRepository _ttsRepository;
  final TTSSettingsStorage _ttsSettingsStorage;

  AudioPlayerService(this._ttsRepository, this._ttsSettingsStorage)
      : super(AudioPlayerState()) {
    _init();
  }

  void _init() {
    _player.positionStream.listen((position) {
      state = state.copyWith(position: position);
    });

    _player.durationStream.listen((duration) {
      if (duration != null) {
        state = state.copyWith(duration: duration);
      }
    });

    _player.playerStateStream.listen((playerState) {
      final isPlaying = playerState.playing;
      final processingState = playerState.processingState;
      if (processingState == ProcessingState.completed) {
        state = state.copyWith(isPlaying: false, position: Duration.zero);
        _player.seek(Duration.zero);
        _player.pause();
      } else {
        state = state.copyWith(isPlaying: isPlaying);
      }
    });
  }

  Future<void> playMessage(String messageId, String text) async {
    if (state.playingMessageId == messageId && !state.isLoading) {
      if (state.isPlaying) {
        await _player.pause();
      } else {
        await _player.play();
      }
      return;
    }

    if (state.playingMessageId != messageId) {
      await _player.stop();
    }

    state = state.copyWith(
        playingMessageId: messageId,
        playingText: text,
        isLoading: true,
        errorMessage: null, // Clear any previous errors
        position: Duration.zero,
        duration: Duration.zero);

    try {
      final engine = await _ttsSettingsStorage.getEngine() ?? 'Browser';

      List<int> bytes = [];

      if (engine == 'Fish Audio') {
        final fishApiKey = await _ttsSettingsStorage.getFishAudioApiKey() ?? '';
        final fishModel =
            await _ttsSettingsStorage.getFishAudioModel() ?? 's2.1-pro';
        final fishRefId =
            await _ttsSettingsStorage.getFishAudioReferenceId() ?? '';

        bytes = await _ttsRepository.getFishAudioBytes(
            text, fishApiKey, fishModel, fishRefId,
            messageId: messageId);
      } else if (engine == 'GPT-SoVITS') {
        final voiceId = await _ttsSettingsStorage.getVoiceId() ?? 'default';
        final gptSovitsUrl = await _ttsSettingsStorage.getGptSovitsUrl();

        bytes = await _ttsRepository.getAudioBytes(
          text,
          voiceId,
          gptSovitsUrl: gptSovitsUrl,
          messageId: messageId,
        );
      } else {
        // Fallback to Web Speech API or fail
        // Since we are in the unified player, WebSpeech doesn't give us bytes.
        // We throw an exception and let the catch block handle it or just do nothing.
        throw Exception(
            'Browser TTS selected, cannot play via unified audio player.');
      }

      if (kIsWeb) {
        await _player.setAudioSource(
            AudioSource.uri(Uri.dataFromBytes(bytes, mimeType: 'audio/wav')));
      } else {
        // Save to temp file on mobile
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/$messageId.wav');
        await file.writeAsBytes(bytes);
        await _player.setFilePath(file.path);
      }

      await _player.setSpeed(state.speed);
      await _player.play();

      state = state.copyWith(isLoading: false);
    } catch (e, stackTrace) {
      state = state.copyWith(isLoading: false);
      state = AudioPlayerState(
        isPlaying: state.isPlaying,
        position: state.position,
        duration: state.duration,
        playingMessageId: state.playingMessageId,
        playingText: state.playingText,
        speed: state.speed,
        isLoading: false,
        errorMessage: _getFriendlyErrorMessage(e),
      );
      debugPrint('Error playing audio: $e');
      try {
        Sentry.captureException(e, stackTrace: stackTrace);
      } catch (sentryError) {
        debugPrint('Sentry failed to capture exception: $sentryError');
      }
    }
  }

  String _getFriendlyErrorMessage(dynamic e) {
    final str = e.toString();
    if (str.contains('Fish Audio API key missing')) {
      return 'Missing Fish Audio API Key. Please add it in Settings.';
    }
    if (str.contains('AuthRetryableFetchException') ||
        str.contains('ERR_NETWORK_CHANGED')) {
      return 'Network connection dropped. Please check your internet and try again.';
    }
    if (str.contains('Failed to fetch')) {
      return 'Failed to connect to the server. An adblocker might be blocking the request.';
    }
    return 'An unexpected error occurred while loading audio.';
  }

  void clearErrorMessage() {
    if (state.errorMessage != null) {
      state = state.clearError();
    }
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    state = state.copyWith(speed: speed);
  }

  void closePlayer() {
    _player.stop();
    state = AudioPlayerState();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

final audioPlayerServiceProvider =
    StateNotifierProvider<AudioPlayerService, AudioPlayerState>((ref) {
  final ttsRepo = ref.watch(ttsRepositoryProvider);
  final ttsSettings = TTSSettingsStorage();
  final service = AudioPlayerService(ttsRepo, ttsSettings);

  ref.listen<String?>(
    chatViewModelProvider.select((state) => state.threadId),
    (previous, next) {
      if (previous != next) {
        service.closePlayer();
      }
    },
  );

  return service;
});
